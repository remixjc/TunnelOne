// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The checks in local/legacy-tools/WireGuard与Clash安全启动.command.
/// Tunnel creation and rollback belong to the provider, so they also work from
/// the menu bar and on-demand without a GUI or a second WireGuard connection.
public protocol ClashSafetyEnvironment {
    func clashConfiguration() throws -> (app: String, core: String)
    func primaryNetwork() throws -> (service: String, interface: String)
    func effectiveProxy() throws -> [String: Any]
    func proxyDictionary(key: String) throws -> [String: Any]?
    func setProxyDictionary(_ value: [String: Any], service: String) throws
    func ipv4RouteInterface() throws -> String
    func tunnelConnected(interface: String) throws -> Bool
    func probe(proxy: Bool) throws -> SafetyProbe
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
    public var stage = "检查 Clash 设置"
    public var result = "checking"
    public var reason: String?
    public var checks: [SafetyProbe] = []
    public var proxySync: String?
    public var activationAttemptID: String?
    public init() {}
}

public struct ClashSafetyStart {
    public struct Preparation {
        let sourceService: String
        let proxy: [String: Any]
    }
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }
    private let environment: ClashSafetyEnvironment
    public init(environment: ClashSafetyEnvironment) { self.environment = environment }

    /// Deliberately checks only the effective top level, never __SCOPED__.
    public static func proxyMatches(_ value: [String: Any]) -> Bool {
        ["HTTP", "HTTPS", "SOCKS"].allSatisfy { kind in
            (value[kind + "Enable"] as? NSNumber)?.intValue == 1 &&
            value[kind + "Proxy"] as? String == "127.0.0.1" &&
            (value[kind + "Port"] as? NSNumber)?.intValue == 7890
        }
    }

    public func prepare() throws -> Preparation {
        let config = try environment.clashConfiguration()
        func matches(_ pattern: String, _ text: String) -> Bool {
            text.range(of: pattern, options: .regularExpression) != nil
        }
        guard matches("(?m)^sysProxy:\\n(?:[ \\t].*\\n)*?[ \\t]+enable: true[ \\t]*$", config.app) else {
            throw Failure("请先在 Clash Party 中开启「系统代理」。")
        }
        guard matches("(?m)^tun:\\n[ \\t]+enable: false[ \\t]*$", config.core) else {
            throw Failure("请先在 Clash Party 中关闭「虚拟网卡 / TUN」。")
        }
        guard matches("(?m)^mixed-port: 7890[ \\t]*$", config.core) else {
            throw Failure("请将 Clash Party 混合端口设为 7890。")
        }
        guard matches("(?m)^mode: rule[ \\t]*$", config.core) else {
            throw Failure("请先将 Clash Party 切换到「规则模式」。")
        }
        let network = try environment.primaryNetwork()
        guard !network.interface.hasPrefix("utun") else {
            throw Failure("当前主网络已被其它隧道接管，请先断开后再连接。")
        }
        guard Self.proxyMatches(try environment.effectiveProxy()) else {
            throw Failure("当前生效的系统代理未指向 Clash，请先在 Clash Party 重新开启系统代理。")
        }
        for scope in ["State", "Setup"] {
            if let proxy = try environment.proxyDictionary(key: "\(scope):/Network/Service/\(network.service)/Proxies"),
               Self.proxyMatches(proxy) {
                return Preparation(sourceService: network.service, proxy: proxy)
            }
        }
        throw Failure("找不到可复制的 Clash 代理配置，尚未启动 WireGuard。")
    }

    /// Called after the provider reports that its adapter is ready. Wait for the
    /// system's Connected state before the command's one-second settling delay.
    /// Every mutation is scoped to this
    /// adapter's actual temporary service; Setup/preferences are never written.
    public func verify(_ preparation: Preparation, interface: String,
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
        guard try environment.ipv4RouteInterface() == interface else {
            throw Failure("WireGuard 未接管 IPv4 上网路由。")
        }
        let network = try environment.primaryNetwork()
        guard network.interface == interface, network.service != preparation.sourceService else {
            throw Failure("当前主网络不是本次 WireGuard 隧道，未修改代理。")
        }
        progress("同步隧道代理")
        var report = SafetyStartReport()
        if Self.proxyMatches(try environment.effectiveProxy()) {
            report.proxySync = "already-effective"
        } else {
            try checkCancellation()
            try environment.setProxyDictionary(preparation.proxy, service: network.service)
            var effective = false
            for _ in 0..<12 {
                try checkCancellation()
                if Self.proxyMatches(try environment.effectiveProxy()) { effective = true; break }
                environment.pause()
            }
            guard effective else { throw Failure("写入后系统代理仍未生效。") }
            report.proxySync = "copied-to-tunnel-state"
        }
        try checkCancellation()
        progress("检查国内直连与国外代理")
        // Both requests run, including when the first fails. Neither a listening
        // port nor a successful explicit proxy request proves system proxy use.
        let group = DispatchGroup()
        let lock = NSLock()
        var probes: [Bool: SafetyProbe] = [:]
        for proxy in [false, true] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let result: SafetyProbe
                do { result = try self.environment.probe(proxy: proxy) }
                catch {
                    result = SafetyProbe(name: proxy ? "国外代理" : "国内直连", ok: false,
                                         http: "000", detail: error.localizedDescription)
                }
                lock.lock(); probes[proxy] = result; lock.unlock()
                group.leave()
            }
        }
        group.wait()
        try checkCancellation()
        report.checks = [probes[false]!, probes[true]!]
        report.stage = "连通性检查完成"
        report.result = report.checks.allSatisfy(\.ok) ? "connected-and-checked" : "failed"
        if report.result == "failed" {
            report.reason = report.checks.filter { !$0.ok }.map(\.failureDescription).joined(separator: "\n")
        }
        return report
    }
}
