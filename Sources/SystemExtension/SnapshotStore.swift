// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if SWIFT_PACKAGE
import TunnelOnePolicy
#endif

/// No caller-provided path is accepted. The service derives the UID from XPC.
/// The system extension never opens the GUI user's keychain or app container.
final class SnapshotStore {
    static let shared = SnapshotStore()
    private let root: URL
    private let owner: uid_t
    private let queue = DispatchQueue(label: "TunnelOne.SnapshotStore")

    init(root: URL = URL(fileURLWithPath: "/Library/Application Support/io.github.remixjc.TunnelOne/Configurations"),
         owner: uid_t = 0) {
        self.root = root
        self.owner = owner
    }

    private func directory(uid: uid_t) throws -> URL {
        guard geteuid() == owner, uid >= 501, uid < UInt32.max - 1 else {
            throw SystemExtensionConfiguration.ConfigurationError.invalid
        }
        // The product directory is also private; never follow a pre-existing link.
        for url in [root.deletingLastPathComponent(), root, root.appendingPathComponent(String(uid))] {
            var info = stat()
            if lstat(url.path, &info) != 0 {
                guard errno == ENOENT, mkdir(url.path, 0o700) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                guard lstat(url.path, &info) == 0 else { throw SystemExtensionConfiguration.ConfigurationError.invalid }
            }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == owner,
                  info.st_mode & 0o777 == 0o700 else {
                throw SystemExtensionConfiguration.ConfigurationError.invalid
            }
        }
        return root.appendingPathComponent(String(uid), isDirectory: true)
    }

    private func path(_ identifier: String, uid: uid_t) throws -> URL {
        guard let id = UUID(uuidString: identifier) else {
            throw SystemExtensionConfiguration.ConfigurationError.invalid
        }
        return try directory(uid: uid).appendingPathComponent(id.uuidString + ".json")
    }

    func save(_ snapshot: SystemExtensionConfiguration, uid: uid_t) throws {
        try queue.sync {
            try snapshot.validate()
            let destination = try path(snapshot.identifier, uid: uid)
            let entries = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
            guard entries.count < 512 else { throw SystemExtensionConfiguration.ConfigurationError.invalid }
            // An immutable snapshot avoids changing a running/on-demand configuration.
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw SystemExtensionConfiguration.ConfigurationError.invalid
            }
            try JSONEncoder().encode(snapshot).write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }

    func load(_ identifier: String, uid: uid_t) throws -> SystemExtensionConfiguration {
        try queue.sync {
            let url = try path(identifier, uid: uid)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == owner, info.st_mode & 0o777 == 0o600,
                  info.st_size <= 9 * 1024 * 1024 else {
                throw SystemExtensionConfiguration.ConfigurationError.invalid
            }
            let snapshot = try JSONDecoder().decode(SystemExtensionConfiguration.self, from: Data(contentsOf: url))
            try snapshot.validate()
            guard UUID(uuidString: snapshot.identifier) == UUID(uuidString: identifier) else {
                throw SystemExtensionConfiguration.ConfigurationError.invalid
            }
            return snapshot
        }
    }

    func remove(_ identifier: String, uid: uid_t) throws {
        try queue.sync {
            let url = try path(identifier, uid: uid)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            let errorURL = url.appendingPathExtension("error")
            if FileManager.default.fileExists(atPath: errorURL.path) { try FileManager.default.removeItem(at: errorURL) }
            let reportURL = url.appendingPathExtension("safety")
            if FileManager.default.fileExists(atPath: reportURL.path) { try FileManager.default.removeItem(at: reportURL) }
        }
    }

    func recordError(_ value: String?, identifier: String, uid: uid_t) {
        queue.sync {
            guard let url = try? path(identifier, uid: uid).appendingPathExtension("error") else { return }
            if let value = value {
                try? Data(value.utf8).write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func lastError(_ identifier: String, uid: uid_t) -> String? {
        queue.sync {
            guard let url = try? path(identifier, uid: uid).appendingPathExtension("error"),
                  let data = try? Data(contentsOf: url), data.count < 4096 else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    func recordSafetyReport(_ report: SafetyStartReport, identifier: String, uid: uid_t) {
        queue.sync {
            guard let url = try? path(identifier, uid: uid).appendingPathExtension("safety"),
                  let data = try? JSONEncoder().encode(report) else { return }
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func safetyReport(_ identifier: String, uid: uid_t) -> Data? {
        queue.sync {
            guard let url = try? path(identifier, uid: uid).appendingPathExtension("safety"),
                  let data = try? Data(contentsOf: url), data.count < 65536 else { return nil }
            return data
        }
    }
}
