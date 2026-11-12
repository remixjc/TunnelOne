// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network
import NetworkExtension

final class ProxyRuntime {
    private var process: Process?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "TunnelOne.ProxyRuntime")
    private var generation = 0
    private var runtimeDirectory: URL?

    static func networkSettings(for settings: ProxySettings) -> NEProxySettings? {
        guard settings.enabled else { return nil }
        let proxy = NEProxySettings()
        proxy.httpEnabled = true
        proxy.httpsEnabled = true
        proxy.httpServer = NEProxyServer(address: settings.effectiveHost, port: settings.port)
        proxy.httpsServer = NEProxyServer(address: settings.effectiveHost, port: settings.port)
        proxy.exceptionList = settings.bypass
        proxy.excludeSimpleHostnames = true
        proxy.matchDomains = [""]
        return proxy
    }

    /// External mode checks the existing Clash port before WireGuard starts.
    /// Built-in mode launches its core after WireGuard installs its routes.
    func start(_ settings: ProxySettings, profileData: Data?, uid: uid_t, gid: gid_t,
               interfaceName: String?, onUnexpectedExit: @escaping () -> Void,
               completion: @escaping (Error?) -> Void) {
        guard settings.enabled else { completion(nil); return }
        queue.async {
            self.generation += 1
            let generation = self.generation
            do {
                if settings.source == .builtIn {
                    guard let profileData = profileData, let interfaceName = interfaceName,
                          let executables = Bundle.main.executableURL?.deletingLastPathComponent() else {
                        throw ProxySettings.ValidationError.profile
                    }
                    let cache = URL(fileURLWithPath: "/private/var/tmp")
                        .appendingPathComponent("TunnelOne-" + UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                    self.runtimeDirectory = cache
                    let profile = cache.appendingPathComponent("profile.yaml")
                    try profileData.write(to: profile, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600,
                                                          .ownerAccountID: uid, .groupOwnerAccountID: gid],
                                                         ofItemAtPath: profile.path)
                    try FileManager.default.setAttributes([.ownerAccountID: uid, .groupOwnerAccountID: gid],
                                                         ofItemAtPath: cache.path)
                    let process = Process()
                    process.executableURL = executables.appendingPathComponent("tunnelone-core-launcher")
                    process.arguments = ["-profile", profile.path, "-directory", cache.path,
                                         "-port", String(settings.port),
                                         "-core", executables.appendingPathComponent("mihomo").path,
                                         "-interface", interfaceName, "-uid", String(uid), "-gid", String(gid)]
                    process.environment = ["PATH": "/usr/bin:/bin", "HOME": cache.path, "TMPDIR": cache.path]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    process.terminationHandler = { _ in onUnexpectedExit() }
                    try process.run()
                    self.process = process
                }
                self.queue.asyncAfter(deadline: .now() + 0.5) {
                    self.waitForPort(settings, generation: generation, deadline: Date().addingTimeInterval(20),
                                     completion: completion)
                }
            } catch {
                self.removeRuntimeDirectory()
                completion(error)
            }
        }
    }

    private func waitForPort(_ settings: ProxySettings, generation: Int, deadline: Date,
                             completion: @escaping (Error?) -> Void) {
        guard generation == self.generation else { return }
        if Date() >= deadline || (settings.source == .builtIn && process?.isRunning != true) {
            let message = settings.source == .external
                ? "Clash 代理端口 \(settings.effectiveHost):\(settings.port) 未就绪，尚未启动 WireGuard。请确认 Clash Party 已启动且混合端口可连接。"
                : "内置代理启动或端口检查失败，请检查配置与端口占用。"
            completion(NSError(domain: "TunnelOne.Proxy", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(settings.effectiveHost),
                                      port: NWEndpoint.Port(rawValue: UInt16(settings.port))!, using: .tcp)
        self.connection = connection
        var finished = false
        let finish: (Bool) -> Void = { ready in
            guard !finished, generation == self.generation else { return }
            finished = true
            connection.cancel()
            self.connection = nil
            if ready {
                completion(nil)
            } else {
                self.queue.asyncAfter(deadline: .now() + 0.25) {
                    self.waitForPort(settings, generation: generation, deadline: deadline, completion: completion)
                }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            case .failed: finish(false)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 1) { finish(false) }
    }

    func stop() {
        queue.sync {
            self.generation += 1
            self.connection?.cancel()
            self.connection = nil
            if let process = self.process {
                process.terminationHandler = nil
                if process.isRunning { process.terminate() }
            }
            self.process = nil
            self.removeRuntimeDirectory()
        }
    }

    private func removeRuntimeDirectory() {
        if let directory = runtimeDirectory { try? FileManager.default.removeItem(at: directory) }
        runtimeDirectory = nil
    }
}
