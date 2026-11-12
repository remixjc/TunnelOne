// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Only the opaque snapshot identifier goes into NetworkExtension preferences.
/// Secrets cross authenticated XPC and are stored in a root-owned directory.
public struct SystemExtensionConfiguration: Codable {
    public static let snapshotKey = "TunnelOneSystemSnapshot"
    public let identifier: String
    public let wireGuard: String
    public let proxy: ProxySettings
    public let profile: Data?

    public init(identifier: String = UUID().uuidString, wireGuard: String,
                proxy: ProxySettings, profile: Data?) {
        self.identifier = identifier
        self.wireGuard = wireGuard
        self.proxy = proxy
        self.profile = profile
    }

    public func validate() throws {
        guard UUID(uuidString: identifier) != nil, !wireGuard.isEmpty,
              wireGuard.utf8.count <= 1024 * 1024 else { throw ConfigurationError.invalid }
        try proxy.validate()
        if proxy.enabled && proxy.source == .builtIn {
            guard let profile = profile, !profile.isEmpty, profile.count <= 5 * 1024 * 1024,
                  String(data: profile, encoding: .utf8) != nil else { throw ConfigurationError.invalid }
        } else if profile != nil {
            throw ConfigurationError.invalid
        }
    }

    public enum ConfigurationError: LocalizedError {
        case invalid, unavailable
        public var errorDescription: String? {
            switch self {
            case .invalid: return "系统扩展配置无效，请重新保存隧道与代理设置。"
            case .unavailable: return "系统扩展尚未就绪。请将 TunnelOne 安装到「应用程序」，并在系统设置中允许网络扩展。"
            }
        }
    }
}

#if os(macOS)
@objc public protocol SystemExtensionControl {
    func putSnapshot(_ data: Data, reply: @escaping (NSError?) -> Void)
    func removeSnapshot(_ identifier: String, reply: @escaping (NSError?) -> Void)
    func lastError(_ identifier: String, reply: @escaping (String?) -> Void)
    func safetyReport(_ identifier: String, reply: @escaping (Data?) -> Void)
}

public enum SystemExtensionIdentity {
    public static func requirement(bundleIdentifier: String) -> String? {
        guard let team = Bundle.main.object(forInfoDictionaryKey: "TunnelOneTeamIdentifier") as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              bundleIdentifier.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else { return nil }
        return "anchor apple generic and identifier \"\(bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}
#endif
