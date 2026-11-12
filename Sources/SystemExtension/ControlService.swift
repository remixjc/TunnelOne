// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

final class ControlService: NSObject, NSXPCListenerDelegate {
    private var listener: NSXPCListener?

    func start() throws {
        guard let network = Bundle.main.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any],
              let name = network["NEMachServiceName"] as? String else {
            throw SystemExtensionConfiguration.ConfigurationError.unavailable
        }
        let listener = NSXPCListener(machServiceName: name)
        listener.delegate = self
        self.listener = listener
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier,
              identifier.hasSuffix(".network-extension"),
              let requirement = SystemExtensionIdentity.requirement(
                bundleIdentifier: String(identifier.dropLast(".network-extension".count))),
              connection.effectiveUserIdentifier >= 501 else { return false }
        // Enforced by XPC on every message, without a PID lookup race.
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: SystemExtensionControl.self)
        connection.exportedObject = UserControl(uid: connection.effectiveUserIdentifier)
        connection.resume()
        return true
    }
}

private final class UserControl: NSObject, SystemExtensionControl {
    private let uid: uid_t
    init(uid: uid_t) { self.uid = uid }

    func putSnapshot(_ data: Data, reply: @escaping (NSError?) -> Void) {
        do {
            guard data.count <= 9 * 1024 * 1024 else { throw SystemExtensionConfiguration.ConfigurationError.invalid }
            let value = try JSONDecoder().decode(SystemExtensionConfiguration.self, from: data)
            try value.validate()
            _ = try TunnelConfiguration(fromWgQuickConfig: value.wireGuard)
            try SnapshotStore.shared.save(value, uid: uid)
            reply(nil)
        } catch {
            // Parser errors can contain private configuration lines.
            reply(SystemExtensionConfiguration.ConfigurationError.invalid as NSError)
        }
    }

    func removeSnapshot(_ identifier: String, reply: @escaping (NSError?) -> Void) {
        do { try SnapshotStore.shared.remove(identifier, uid: uid); reply(nil) }
        catch { reply(SystemExtensionConfiguration.ConfigurationError.invalid as NSError) }
    }

    func lastError(_ identifier: String, reply: @escaping (String?) -> Void) {
        reply(SnapshotStore.shared.lastError(identifier, uid: uid))
    }
}
