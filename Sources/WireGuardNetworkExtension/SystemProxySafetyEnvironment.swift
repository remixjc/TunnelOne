// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SystemConfiguration

final class MacSystemProxySafetyEnvironment: SystemProxySafetyEnvironment {
    struct NetworkUnavailable: Error {}
    private let store = SCDynamicStoreCreate(nil, "TunnelOne.SystemProxy" as CFString, nil, nil)!
    private let performActiveMutation: (() throws -> Void) throws -> Void
    private let directProbe: () throws -> SafetyProbe
    private let isCancelled: () -> Bool
    private var observer: SCDynamicStore?

    init(performActiveMutation: @escaping (() throws -> Void) throws -> Void,
         isCancelled: @escaping () -> Bool, directProbe: @escaping () throws -> SafetyProbe) {
        self.performActiveMutation = performActiveMutation
        self.isCancelled = isCancelled
        self.directProbe = directProbe
    }

    func primaryNetwork() throws -> (service: String, interface: String) {
        guard let value = value("State:/Network/Global/IPv4"),
              let service = value["PrimaryService"] as? String, UUID(uuidString: service) != nil,
              let interface = value["PrimaryInterface"] as? String else {
            throw SystemProxySafetyStart.Failure("无法确定当前主网络服务。")
        }
        return (service, interface)
    }

    func effectiveProxy() throws -> [String: Any] {
        guard let proxy = SCDynamicStoreCopyProxies(store) as? [String: Any] else {
            throw SystemProxySafetyStart.Failure("无法读取系统代理配置。")
        }
        return proxy
    }

    private func value(_ key: String) -> [String: Any]? {
        SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
    }

    func sourceProxy(service: String) throws -> SystemProxySnapshot {
        try SystemProxySnapshot(dictionary: value("State:/Network/Service/\(service)/Proxies") ??
            value("Setup:/Network/Service/\(service)/Proxies") ?? [:])
    }

    /// Use active physical services in the configured service order. The VPN's
    /// effective/global proxy dictionary is never used as its own new source.
    func refreshedSource(_ previous: SystemProxySafetyStart.Preparation) throws -> SystemProxySafetyStart.Preparation {
        let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv4" as CFString) as? [String] ?? []
        let order = value("Setup:/Network/Global/IPv4")?["ServiceOrder"] as? [String] ?? []
        var candidates: [(String, String)] = []
        for key in keys {
            let parts = key.split(separator: "/")
            guard parts.count == 5, let state = value(key), let name = state["InterfaceName"] as? String,
                  !name.hasPrefix("utun"), !(state["Addresses"] as? [String] ?? []).isEmpty else { continue }
            let service = String(parts[3])
            guard UUID(uuidString: service) != nil else { continue }
            candidates.append((service, name))
        }
        candidates.sort {
            let lhs = order.firstIndex(of: $0.0) ?? Int.max
            let rhs = order.firstIndex(of: $1.0) ?? Int.max
            if lhs != rhs { return lhs < rhs }
            return $0.0 < $1.0
        }
        guard let source = candidates.first else {
            throw NetworkUnavailable()
        }
        let proxy = try sourceProxy(service: source.0)
        // A system-wide policy may supply the initial effective settings. An
        // unrelated notification must not replace it with an empty service.
        if source.0 == previous.sourceService, proxy == previous.observedSource { return previous }
        return SystemProxySafetyStart.Preparation(sourceService: source.0, sourceInterface: source.1,
                                                proxy: proxy, observedSource: proxy)
    }

    func tunnelService(interface: String) throws -> String {
        for family in ["IPv4", "IPv6"] {
            let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/\(family)" as CFString) as? [String] ?? []
            for key in keys where value(key)?["InterfaceName"] as? String == interface {
                let parts = key.split(separator: "/")
                if parts.count == 5, UUID(uuidString: String(parts[3])) != nil { return String(parts[3]) }
            }
        }
        throw SystemProxySafetyStart.Failure("未找到属于本次 WireGuard 接口的临时网络服务。")
    }

    func setProxyDictionary(_ value: [String: Any], service: String) throws {
        try performActiveMutation {
            guard UUID(uuidString: service) != nil,
                  SCDynamicStoreSetValue(store, "State:/Network/Service/\(service)/Proxies" as CFString, value as CFDictionary) else {
                throw SystemProxySafetyStart.Failure("同步本次隧道的临时系统代理失败。")
            }
        }
    }

    func tunnelConnected(interface: String) throws -> Bool {
        guard let preferences = SCPreferencesCreate(nil, "TunnelOne.SystemProxy" as CFString, nil),
              let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else { return false }
        for service in services {
            guard let id = SCNetworkServiceGetServiceID(service),
                  let connection = SCNetworkConnectionCreateWithServiceID(nil, id, nil, nil),
                  SCNetworkConnectionGetStatus(connection) == .connected,
                  let status = SCNetworkConnectionCopyExtendedStatus(connection) as? [String: Any],
                  let ipv4 = status["IPv4"] as? [String: Any],
                  ipv4["InterfaceName"] as? String == interface else { continue }
            return true
        }
        return false
    }

    func probe(snapshot: SystemProxySnapshot?, useSystem: Bool) throws -> SafetyProbe {
        guard let snapshot = snapshot else { return try directProbe() }
        return SystemProxyProbe.run(snapshot: useSystem ? nil : snapshot, isCancelled: isCancelled)
    }

    func pause() { Thread.sleep(forTimeInterval: 0.25) }

    private final class WatchBox {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
    }

    func observeChanges(_ handler: @escaping () -> Void) throws {
        stopObserving()
        let box = WatchBox(handler)
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: { pointer in
            _ = Unmanaged<WatchBox>.fromOpaque(pointer).retain()
            return pointer
        }, release: { pointer in
            Unmanaged<WatchBox>.fromOpaque(pointer).release()
        }, copyDescription: nil)
        guard let observer = SCDynamicStoreCreate(nil, "TunnelOne.ProxyChanges" as CFString, { _, _, context in
            guard let context = context else { return }
            Unmanaged<WatchBox>.fromOpaque(context).takeUnretainedValue().handler()
        }, &context),
        SCDynamicStoreSetNotificationKeys(observer, nil, [
            "State:/Network/Service/.*/Proxies", "Setup:/Network/Service/.*/Proxies",
            "State:/Network/Service/.*/IPv4", "Setup:/Network/Global/IPv4"
        ] as CFArray), SCDynamicStoreSetDispatchQueue(observer, .main) else {
            throw SystemProxySafetyStart.Failure("无法监听系统代理变化。")
        }
        self.observer = observer
    }

    func stopObserving() {
        if let observer = observer { SCDynamicStoreSetDispatchQueue(observer, nil) }
        observer = nil
    }
    deinit { stopObserving() }
}
