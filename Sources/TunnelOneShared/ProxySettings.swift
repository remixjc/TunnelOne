// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Stored beside, rather than inside, the portable WireGuard configuration.
public struct ProxySettings: Codable, Equatable {
    public enum Source: String, Codable { case builtIn, external }
    public static let configurationKey = "TunnelOneProxy"
    public var enabled = false
    public var source: Source = .builtIn
    public var host = "127.0.0.1"
    public var port = 17890
    public var bypass = ["localhost", "*.local", "127.0.0.1", "::1"]
    public var profileID: String?

    public init() {}

    public var effectiveHost: String { source == .builtIn ? "127.0.0.1" : host }

    public func validate() throws {
        guard (1024...65535).contains(port) else { throw ValidationError.port }
        guard !host.isEmpty, host.utf8.count <= 253,
              !host.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "@" }),
              !host.contains("://") else { throw ValidationError.host }
        if let profileID = profileID, UUID(uuidString: profileID) == nil {
            throw ValidationError.profile
        }
        if enabled && source == .builtIn && profileID == nil {
            throw ValidationError.profile
        }
        guard bypass.count <= 128, bypass.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 253 }) else {
            throw ValidationError.bypass
        }
    }

    /// Missing settings mean a newly imported tunnel. Corrupt settings fail closed.
    public static func decode(_ data: Data?) throws -> ProxySettings {
        guard let data = data else { return ProxySettings() }
        let settings = try JSONDecoder().decode(Self.self, from: data)
        try settings.validate()
        return settings
    }

    public static func decodeProviderValue(_ value: Any?) throws -> ProxySettings {
        guard let value = value else { return ProxySettings() }
        guard let data = value as? Data else { throw ValidationError.configuration }
        return try decode(data)
    }

    public func encoded() throws -> Data {
        try validate()
        return try JSONEncoder().encode(self)
    }

    public enum ValidationError: LocalizedError {
        case port, host, profile, bypass, configuration
        public var errorDescription: String? {
            switch self {
            case .port: return "端口必须在 1024–65535 之间。"
            case .host: return "请填写代理主机名或 IP，不包含协议、路径或认证信息。"
            case .profile: return "请先导入有效的 Mihomo / Clash YAML 配置。"
            case .bypass: return "代理例外列表无效（最多 128 项）。"
            case .configuration: return "代理配置数据已损坏，请重新保存设置。"
            }
        }
    }
}
