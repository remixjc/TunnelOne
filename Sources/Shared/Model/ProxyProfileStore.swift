// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum ProxyProfileStore {
    static func directory() throws -> URL {
        guard let shared = FileManager.sharedFolderURL else {
            throw NSError(domain: "TunnelOne", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "无法访问共享容器。请检查应用和扩展的签名及 App Group 权限。"
            ])
        }
        let directory = shared.appendingPathComponent("ProxyProfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    static func profileURL(id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw ProxySettings.ValidationError.profile }
        return try directory().appendingPathComponent(id + ".yaml")
    }

    static func write(_ data: Data, id: String) throws {
        guard !data.isEmpty, data.count <= 5 * 1024 * 1024,
              String(data: data, encoding: .utf8) != nil else {
            throw NSError(domain: "TunnelOne", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "请选择 5 MB 以内的 UTF-8 YAML 配置文件。"
            ])
        }
        let url = try profileURL(id: id)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
