// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// System proxy inheritance is independent of a proxy client's brand or files.
public protocol SystemProxySafetyEnvironment {
    func primaryNetwork() throws -> (service: String, interface: String)
    func effectiveProxy() throws -> [String: Any]
    func tunnelService(interface: String) throws -> String
    func setProxyDictionary(_ value: [String: Any], service: String) throws
    func tunnelConnected(interface: String) throws -> Bool
    func probe(snapshot: SystemProxySnapshot?, useSystem: Bool) throws -> SafetyProbe
    func pause()
}

public struct SafetyProbe: Codable, Equatable {
    public let name: String
    public let ok: Bool
    public let http: String
    public let exitCode: Int32?
    public let detail: String?
    public let transport: String?
    public init(name: String, ok: Bool, http: String, exitCode: Int32? = nil, detail: String? = nil,
                transport: String? = nil) {
        self.name = name; self.ok = ok; self.http = http
        self.exitCode = exitCode; self.detail = detail
        self.transport = transport
    }
    public var failureDescription: String {
        let code = exitCode.map { "，curl \($0)" } ?? ""
        return "\(name)未通过（HTTP \(http.isEmpty ? "000" : http)\(code)）" +
            (detail.flatMap { $0.isEmpty ? nil : "：\($0)" } ?? "")
    }
}

public struct SafetyStartReport: Codable {
    public var time: String = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }()
    public var stage = "读取当前系统代理"
    public var result = "checking"
    public var reason: String?
    public var checks: [SafetyProbe] = []
    public var proxySync: String?
    public var proxySummary: String?
    public var proxyApplied: Bool?
    public var activationAttemptID: String?
    public init() {}
}

public struct SystemProxySafetyStart {
    public struct Preparation {
        public let sourceService: String
        public let sourceInterface: String
        public let proxy: SystemProxySnapshot
        public let observedSource: SystemProxySnapshot
        public init(sourceService: String, sourceInterface: String, proxy: SystemProxySnapshot,
                    observedSource: SystemProxySnapshot? = nil) {
            self.sourceService = sourceService; self.sourceInterface = sourceInterface; self.proxy = proxy
            self.observedSource = observedSource ?? proxy
        }
    }
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }
    private let environment: SystemProxySafetyEnvironment
    public init(environment: SystemProxySafetyEnvironment) { self.environment = environment }

    public func prepare() throws -> Preparation {
        let network = try environment.primaryNetwork()
        guard !network.interface.hasPrefix("utun") else {
            throw Failure("检测到现有 VPN / TUN 正在接管主网络。当前自动继承仅支持系统代理模式，请先处理路由冲突。")
        }
        let proxy = try SystemProxySnapshot(dictionary: environment.effectiveProxy())
        // Validate the actual system settings before WireGuard can change routes.
        if proxy.hasProxy {
            let check = try environment.probe(snapshot: proxy, useSystem: false)
            guard check.ok else { throw Failure("连接前系统代理不可用：" + check.failureDescription) }
        }
        return Preparation(sourceService: network.service, sourceInterface: network.interface, proxy: proxy)
    }

    /// Called after the provider reports that its adapter is ready. Wait for the
    /// system's Connected state before the command's one-second settling delay.
    /// Every mutation is scoped to this
    /// adapter's actual temporary service; Setup/preferences are never written.
    public func verify(_ preparation: Preparation, interface: String, checkDirect: Bool = true,
                       isCancelled: () -> Bool = { false },
                       progress: (String) -> Void = { _ in }) throws -> SafetyStartReport {
        func checkCancellation() throws {
            if isCancelled() { throw CancellationError() }
        }
        try checkCancellation()
        guard interface.hasPrefix("utun") else { throw Failure("无法确定本次 WireGuard 接口。") }
        progress("等待系统确认 WireGuard 已连接")
        var connected = false
        for _ in 0..<120 {
            try checkCancellation()
            if try environment.tunnelConnected(interface: interface) { connected = true; break }
            environment.pause()
        }
        guard connected else { throw Failure("等待系统确认 WireGuard Connected 超时。") }
        progress("WireGuard 已连接，等待网络稳定")
        for _ in 0..<4 {
            try checkCancellation()
            environment.pause()
        }
        try checkCancellation()
        guard try environment.tunnelConnected(interface: interface) else {
            throw Failure("WireGuard 在联网检查前已断开。")
        }
        let service = try environment.tunnelService(interface: interface)
        guard service != preparation.sourceService else { throw Failure("本次隧道服务归属无效。") }
        progress("同步隧道代理")
        var report = SafetyStartReport()
        report.proxySummary = preparation.proxy.summary
        report.proxyApplied = preparation.proxy.hasProxy
        if (try? SystemProxySnapshot(dictionary: environment.effectiveProxy())) == preparation.proxy {
            report.proxySync = "already-effective"
        } else {
            try checkCancellation()
            try environment.setProxyDictionary(preparation.proxy.dictionary, service: service)
            var effective = false
            for _ in 0..<12 {
                try checkCancellation()
                if (try? SystemProxySnapshot(dictionary: environment.effectiveProxy())) == preparation.proxy {
                    effective = true; break
                }
                environment.pause()
            }
            guard effective else { throw Failure("写入后系统代理与连接前的设置不一致。") }
            report.proxySync = "copied-to-tunnel-state"
        }
        try checkCancellation()
        progress("验证 WireGuard 与系统代理访问")
        // Both requests run, including when the first fails. Neither a listening
        // port nor a successful explicit proxy request proves system proxy use.
        let group = DispatchGroup()
        let lock = NSLock()
        var probes: [Bool: SafetyProbe] = [:]
        let targets = (checkDirect ? [false] : []) + (preparation.proxy.hasProxy ? [true] : [])
        for proxy in targets {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let result: SafetyProbe
                do { result = try self.environment.probe(snapshot: proxy ? preparation.proxy : nil, useSystem: proxy) }
                catch {
                    result = SafetyProbe(name: proxy ? "系统代理访问" : "WireGuard 公网直连", ok: false,
                                         http: "000", detail: error.localizedDescription)
                }
                lock.lock(); probes[proxy] = result; lock.unlock()
                group.leave()
            }
        }
        group.wait()
        try checkCancellation()
        report.checks = targets.compactMap { probes[$0] }
        report.stage = preparation.proxy.hasProxy ? "已沿用系统代理，访问检查完成" : "WireGuard 已连接，未启用系统代理"
        report.result = report.checks.allSatisfy(\.ok) ? (preparation.proxy.hasProxy ? "connected-and-checked" : "connected-without-proxy") : "failed"
        if report.result == "failed" {
            report.reason = report.checks.filter { !$0.ok }.map(\.failureDescription).joined(separator: "\n")
        }
        return report
    }
}
