// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import NetworkExtension

enum SystemExtensionClient {
    private static func request<T>(_ operation: @escaping (SystemExtensionControl, @escaping (T?, Error?) -> Void) -> Void,
                                   completion: @escaping (T?, Error?) -> Void) {
        guard let service = Bundle.main.object(forInfoDictionaryKey: "TunnelOneMachServiceName") as? String,
              let app = Bundle.main.bundleIdentifier,
              let requirement = SystemExtensionIdentity.requirement(bundleIdentifier: app + ".network-extension") else {
            completion(nil, SystemExtensionConfiguration.ConfigurationError.unavailable)
            return
        }
        let connection = NSXPCConnection(machServiceName: service, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: SystemExtensionControl.self)
        var completed = false // accessed exclusively on the main queue
        let finish: (T?, Error?) -> Void = { value, error in
            DispatchQueue.main.async {
                guard !completed else { return }
                completed = true
                connection.invalidationHandler = nil
                connection.invalidate()
                completion(value, error)
            }
        }
        connection.invalidationHandler = { finish(nil, SystemExtensionConfiguration.ConfigurationError.unavailable) }
        connection.resume()
        let remote = connection.remoteObjectProxyWithErrorHandler { _ in
            finish(nil, SystemExtensionConfiguration.ConfigurationError.unavailable)
        }
        guard let service = remote as? SystemExtensionControl else {
            finish(nil, SystemExtensionConfiguration.ConfigurationError.unavailable); return
        }
        operation(service, finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            finish(nil, SystemExtensionConfiguration.ConfigurationError.unavailable)
        }
    }

    static func save(_ snapshot: SystemExtensionConfiguration, completion: @escaping (Error?) -> Void) {
        do {
            try snapshot.validate()
            let data = try JSONEncoder().encode(snapshot)
            request({ service, reply in service.putSnapshot(data) { reply(true, $0) } }) {
                (_: Bool?, error) in completion(error)
            }
        } catch { completion(error) }
    }

    static func remove(_ identifier: String) {
        request({ service, reply in service.removeSnapshot(identifier) { reply(true, $0) } }) {
            (_: Bool?, _) in
        }
    }

    static func lastError(_ identifier: String, completion: @escaping (String?) -> Void) {
        request({ service, reply in service.lastError(identifier) { reply($0, nil) } }) {
            (value: String?, _) in completion(value)
        }
    }

    static func safetyReport(_ identifier: String, completion: @escaping (SafetyStartReport?) -> Void) {
        request({ service, reply in service.safetyReport(identifier) { reply($0, nil) } }) {
            (value: Data?, _) in completion(value.flatMap { try? JSONDecoder().decode(SafetyStartReport.self, from: $0) })
        }
    }

    /// The Mach service includes this app's build number. A successful reply
    /// proves the extension for this build implements the safety report API.
    static func requireSafetySupport(completion: @escaping (Error?) -> Void) {
        request({ service, reply in service.safetyReport(UUID().uuidString) { _ in reply(true, nil) } }) {
            (ready: Bool?, error) in
            completion(ready == true && error == nil ? nil : ClashSafetyStart.Failure(
                "新版网络扩展尚未就绪，尚未启动连接。请先完成 TunnelOne 网络扩展的安装 / 更新。"))
        }
    }
}

extension NETunnelProviderManager {
    /// Commit the immutable, root-owned secret snapshot before saving its ID.
    /// A failed preference save removes the staged snapshot and restores metadata.
    func saveTunnelPreferences(completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              proto.providerConfiguration?["UID"] as? uid_t == getuid(),
              let config = proto.asTunnelConfiguration() else {
            completionHandler(SystemExtensionConfiguration.ConfigurationError.invalid); return
        }
        do {
            let proxy = try ProxySettings.decodeProviderValue(proto.providerConfiguration?[ProxySettings.configurationKey])
            let profile: Data?
            if proxy.enabled && proxy.source == .builtIn, let id = proxy.profileID {
                profile = try Data(contentsOf: ProxyProfileStore.profileURL(id: id))
            } else { profile = nil }
            let snapshot = SystemExtensionConfiguration(wireGuard: config.asWgQuickConfig(), proxy: proxy, profile: profile)
            let previous = proto.providerConfiguration
            SystemExtensionClient.save(snapshot) { error in
                guard error == nil else { completionHandler(error); return }
                proto.providerConfiguration?[SystemExtensionConfiguration.snapshotKey] = snapshot.identifier
                self.saveToPreferences { error in
                    DispatchQueue.main.async {
                        if let error = error {
                            proto.providerConfiguration = previous
                            SystemExtensionClient.remove(snapshot.identifier)
                            completionHandler(error)
                        } else {
                            if let old = previous?[SystemExtensionConfiguration.snapshotKey] as? String {
                                SystemExtensionClient.remove(old)
                            }
                            completionHandler(nil)
                        }
                    }
                }
            }
        } catch { completionHandler(error) }
    }
}
