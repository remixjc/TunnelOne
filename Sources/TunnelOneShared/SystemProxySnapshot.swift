// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A normalized, allowlisted copy of the system proxy configuration.
/// Scoped dictionaries and client-private configuration are never imported.
public struct SystemProxySnapshot: Codable, Equatable {
    public struct Endpoint: Codable, Equatable {
        public let host: String
        public let port: Int
        public init(host: String, port: Int) throws {
            guard !host.isEmpty, host.utf8.count <= 253,
                  !host.contains(where: { $0.isWhitespace || "/@?#\\".contains($0) }),
                  !host.contains("://"), (1...65535).contains(port) else {
                throw SystemProxySafetyStart.Failure("系统代理的主机或端口无效。")
            }
            self.host = host
            self.port = port
        }
        public var description: String { "\(host.contains(":") ? "[\(host)]" : host):\(port)" }
    }

    public let http: Endpoint?
    public let https: Endpoint?
    public let socks: Endpoint?
    public let pacURL: URL?
    public let pacScript: String?
    public let exceptions: [String]
    public let excludeSimpleHostnames: Bool
    public var hasProxy: Bool { http != nil || https != nil || socks != nil || pacURL != nil || pacScript != nil }

    public init(dictionary: [String: Any]) throws {
        func enabled(_ key: String) -> Bool { (dictionary[key] as? NSNumber)?.intValue == 1 }
        func endpoint(_ kind: String) throws -> Endpoint? {
            guard enabled(kind + "Enable") else { return nil }
            guard let host = dictionary[kind + "Proxy"] as? String,
                  let number = dictionary[kind + "Port"] as? NSNumber,
                  number.doubleValue == Double(number.intValue) else {
                throw SystemProxySafetyStart.Failure("系统 \(kind) 代理已开启，但地址或端口缺失。")
            }
            return try Endpoint(host: host, port: number.intValue)
        }
        http = try endpoint("HTTP")
        https = try endpoint("HTTPS")
        socks = try endpoint("SOCKS")
        if enabled("ProxyAutoDiscoveryEnable") {
            throw SystemProxySafetyStart.Failure("检测到 WPAD 自动发现代理。当前版本需要明确的 PAC 地址或手动系统代理。")
        }
        var url: URL?
        var script: String?
        if enabled("ProxyAutoConfigEnable") {
            if let value = dictionary["ProxyAutoConfigJavaScript"] as? String, !value.isEmpty,
               value.utf8.count <= 1024 * 1024 {
                script = value
            } else if let value = dictionary["ProxyAutoConfigURLString"] as? String,
                      value.utf8.count <= 8192, let parsed = URL(string: value),
                      ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
                      parsed.host != nil, parsed.user == nil, parsed.password == nil {
                url = parsed
            } else {
                throw SystemProxySafetyStart.Failure("系统自动代理已开启，但 PAC 地址或脚本无效。")
            }
        }
        pacURL = url
        pacScript = script
        let list = dictionary["ExceptionsList"] as? [String] ?? []
        guard list.count <= 512, list.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else {
            throw SystemProxySafetyStart.Failure("系统代理绕过列表无效或过大。")
        }
        exceptions = list
        excludeSimpleHostnames = enabled("ExcludeSimpleHostnames")
    }

    public var dictionary: [String: Any] {
        var value: [String: Any] = [
            "HTTPEnable": http == nil ? 0 : 1, "HTTPSEnable": https == nil ? 0 : 1,
            "SOCKSEnable": socks == nil ? 0 : 1, "ProxyAutoDiscoveryEnable": 0,
            "ProxyAutoConfigEnable": pacURL != nil || pacScript != nil ? 1 : 0,
            "ExceptionsList": exceptions, "ExcludeSimpleHostnames": excludeSimpleHostnames ? 1 : 0
        ]
        for (kind, endpoint) in [("HTTP", http), ("HTTPS", https), ("SOCKS", socks)] {
            if let endpoint = endpoint {
                value[kind + "Proxy"] = endpoint.host
                value[kind + "Port"] = endpoint.port
            }
        }
        if let url = pacURL { value["ProxyAutoConfigURLString"] = url.absoluteString }
        if let script = pacScript { value["ProxyAutoConfigJavaScript"] = script }
        return value
    }

    /// Do not expose PAC URLs, inline scripts or credentials in UI/reports.
    public var summary: String {
        var items: [String] = []
        if pacURL != nil || pacScript != nil { items.append("PAC 自动代理") }
        for (kind, endpoint) in [("HTTP", http), ("HTTPS", https), ("SOCKS", socks)] {
            if let endpoint = endpoint { items.append("\(kind) \(endpoint.description)") }
        }
        return items.isEmpty ? "未启用系统代理" : items.joined(separator: " · ")
    }
}
