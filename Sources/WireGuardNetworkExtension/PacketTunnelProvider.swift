// SPDX-License-Identifier: GPL-3.0-or-later
// Based on WireGuard Apple (MIT), Copyright © 2018-2023 WireGuard LLC.

import Foundation
import NetworkExtension
import os

class PacketTunnelProvider: NEPacketTunnelProvider {
    private let proxyRuntime = ProxyRuntime()
    // All lifecycle state below is serialized on the main queue.
    private var generation = 0
    private var proxyReady = false
    private var proxyExited = false
    private var pendingStart: ((Error?) -> Void)?
    private var snapshotID: String?
    private var ownerUID: uid_t?
    private var safetyReport = SafetyStartReport()
    private var safetyCancellation: SafetyCancellation?
    private lazy var adapter: WireGuardAdapter = {
        WireGuardAdapter(with: self) { level, message in
            wg_log(level.osLogLevel, message: message)
        }
    }()

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            self.beginStart(options: options, completion: completionHandler)
        }
    }

    private func beginStart(options: [String: NSObject]?, completion: @escaping (Error?) -> Void) {
        guard pendingStart == nil else {
            completion(NSError(domain: "TunnelOne.Lifecycle", code: 1))
            return
        }
        generation += 1
        let generation = self.generation
        pendingStart = completion
        proxyReady = false
        proxyExited = false
        Logger.configureGlobal(tagged: "NET", withFilePath: nil)
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let id = proto.providerConfiguration?[SystemExtensionConfiguration.snapshotKey] as? String,
              let uid = proto.providerConfiguration?["UID"] as? uid_t,
              let snapshot = try? SnapshotStore.shared.load(id, uid: uid),
              let tunnel = try? TunnelConfiguration(fromWgQuickConfig: snapshot.wireGuard),
              let account = getpwuid(uid), uid >= 501 else {
            finishStart(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
            return
        }
        snapshotID = id
        ownerUID = uid
        SnapshotStore.shared.recordError(nil, identifier: id, uid: uid)
        let gid = account.pointee.pw_gid
        let home = URL(fileURLWithPath: String(cString: account.pointee.pw_dir))
        let proxy = snapshot.proxy
        safetyCancellation?.cancel()
        let cancellation = SafetyCancellation()
        safetyCancellation = cancellation
        safetyReport = SafetyStartReport()
        safetyReport.activationAttemptID = options?["activationAttemptId"] as? String
        if proxy.enabled && proxy.source == .external {
            saveSafetyReport()
            DispatchQueue.global(qos: .utility).async {
                do {
                    guard proxy.host == "127.0.0.1", proxy.port == 7890 else {
                        throw ClashSafetyStart.Failure("安全启动使用 Clash Party 的本机混合端口 127.0.0.1:7890。")
                    }
                    let policy = ClashSafetyStart(environment: MacClashSafetyEnvironment(home: home,
                        performActiveMutation: { try cancellation.performActiveMutation($0) }))
                    let preparation = try policy.prepare()
                    DispatchQueue.main.async {
                        guard generation == self.generation, !cancellation.isCancelled else { return }
                        self.safetyReport.stage = "等待 Clash 代理端口就绪"
                        self.saveSafetyReport()
                        // External Clash must be listening before WireGuard changes routes.
                        self.proxyRuntime.start(proxy, profileData: nil, uid: uid, gid: gid,
                                                interfaceName: nil, onUnexpectedExit: {}) { error in
                            DispatchQueue.main.async {
                                guard generation == self.generation, !cancellation.isCancelled else { return }
                                if let error = error {
                                    self.failSafetyPreflight(error)
                                    return
                                }
                                self.safetyReport.stage = "启动 WireGuard"
                                self.saveSafetyReport()
                                self.startAdapter(tunnel, snapshot: snapshot, uid: uid, gid: gid,
                                                  generation: generation, policy: policy, preparation: preparation)
                            }
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard generation == self.generation else { return }
                        self.failSafetyPreflight(error)
                    }
                }
            }
        } else {
            safetyReport.result = "not-requested"
            saveSafetyReport()
            startAdapter(tunnel, snapshot: snapshot, uid: uid, gid: gid, generation: generation)
        }
    }

    private func startAdapter(_ tunnel: TunnelConfiguration, snapshot: SystemExtensionConfiguration,
                              uid: uid_t, gid: gid_t, generation: Int,
                              policy: ClashSafetyStart? = nil, preparation: ClashSafetyStart.Preparation? = nil) {
        let proxy = snapshot.proxy
        adapter.proxySettings = ProxyRuntime.networkSettings(for: proxy)
        adapter.start(tunnelConfiguration: tunnel) { adapterError in
            DispatchQueue.main.async {
                guard generation == self.generation else { return }
                if let error = adapterError {
                    let mapped = self.reportAdapterError(error)
                    self.recordError(mapped)
                    self.safetyReport.result = "failed"
                    self.safetyReport.reason = "WireGuard 启动失败。"
                    self.safetyReport.stage = "隧道未能建立"
                    self.saveSafetyReport()
                    self.finishStart(mapped)
                    return
                }
                wg_log(.info, message: "WireGuard interface: \(self.adapter.interfaceName ?? "unknown")")
                if let policy = policy, let preparation = preparation {
                    self.safetyReport.stage = "等待系统确认 WireGuard 已连接"
                    self.saveSafetyReport()
                    // The installed routes and running adapter are ready for packets.
                    // Releasing start lets macOS actually transition to Connected.
                    self.finishStart(nil)
                    self.verifySafety(policy, preparation: preparation, generation: generation)
                    return
                }
                self.proxyRuntime.start(proxy, profileData: snapshot.profile, uid: uid, gid: gid,
                                        interfaceName: self.adapter.interfaceName,
                                        onUnexpectedExit: { [weak self] in
                    DispatchQueue.main.async {
                        guard let self = self, generation == self.generation else { return }
                        self.proxyExited = true
                        guard self.proxyReady else { return }
                        self.proxyReady = false
                        self.recordError(.couldNotStartProxy)
                        wg_log(.error, staticMessage: "Proxy core exited unexpectedly; disconnecting tunnel")
                        self.cancelTunnelWithError(NSError(domain: "TunnelOne.Proxy", code: 2))
                    }
                }) { error in
                    DispatchQueue.main.async {
                        guard generation == self.generation else { return }
                        let startupError = error ?? (self.proxyExited ? NSError(domain: "TunnelOne.Proxy", code: 2) : nil)
                        if let error = startupError {
                            wg_log(.error, staticMessage: "Proxy startup failed; rolling back WireGuard")
                            self.rollbackSafety(error, generation: generation)
                        } else {
                            self.proxyReady = proxy.enabled
                            wg_log(.info, staticMessage: "Tunnel startup completed; proxy listener check passed")
                            self.finishStart(nil)
                        }
                    }
                }
            }
        }
    }

    private func failSafetyPreflight(_ error: Error) {
        safetyReport.stage = "前置检查未通过，尚未启动 WireGuard"
        safetyReport.result = "preflight-failed"
        safetyReport.reason = error.localizedDescription
        saveSafetyReport()
        recordError(.safetyCheckFailed)
        proxyRuntime.stop()
        finishStart(error)
    }

    private func verifySafety(_ policy: ClashSafetyStart, preparation: ClashSafetyStart.Preparation, generation: Int) {
        let interface = adapter.interfaceName ?? ""
        guard let cancellation = safetyCancellation else { return }
        DispatchQueue.global(qos: .utility).async {
            do {
                let report = try policy.verify(preparation, interface: interface,
                                               isCancelled: { cancellation.isCancelled }, progress: { stage in
                    DispatchQueue.main.async {
                        guard generation == self.generation else { return }
                        self.safetyReport.stage = stage
                        self.saveSafetyReport()
                    }
                })
                DispatchQueue.main.async {
                    guard generation == self.generation else { return }
                    var report = report
                    report.time = self.safetyReport.time
                    report.activationAttemptID = self.safetyReport.activationAttemptID
                    self.safetyReport = report
                    if report.result == "connected-and-checked" {
                        self.proxyReady = true
                        self.saveSafetyReport()
                        wg_log(.info, staticMessage: "Clash settings, WireGuard route, effective HTTP/HTTPS/SOCKS proxies and both connectivity probes passed")
                    } else {
                        self.rollbackSafety(ClashSafetyStart.Failure(report.reason ?? "连通检查失败。"),
                                            generation: generation)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard generation == self.generation else { return }
                    self.rollbackSafety(error, generation: generation)
                }
            }
        }
    }

    private func rollbackSafety(_ error: Error, generation: Int) {
        safetyCancellation?.cancel()
        proxyReady = false
        let wasStarting = pendingStart != nil
        safetyReport.stage = "正在自动断开本次 WireGuard"
        safetyReport.result = "rolling-back"
        safetyReport.reason = error.localizedDescription
        saveSafetyReport()
        recordError(wasStarting ? .couldNotStartProxy : .safetyCheckFailed)
        proxyRuntime.stop()
        adapter.stop { adapterError in
            DispatchQueue.main.async {
                guard generation == self.generation else { return }
                self.safetyReport.stage = adapterError == nil ? "已自动断开本次 WireGuard，保留原有 Clash 代理" : "自动断开失败，请手动断开 WireGuard"
                self.safetyReport.result = adapterError == nil ? "failed" : "rollback-failed"
                self.saveSafetyReport()
                if wasStarting {
                    self.finishStart(error)
                } else {
                    self.cancelTunnelWithError(error)
                }
            }
        }
    }

    private func saveSafetyReport() {
        guard let id = snapshotID, let uid = ownerUID else { return }
        SnapshotStore.shared.recordSafetyReport(safetyReport, identifier: id, uid: uid)
    }

    private func finishStart(_ error: Error?) {
        let completion = pendingStart
        pendingStart = nil
        completion?(error)
    }

    private func recordError(_ error: PacketTunnelProviderError) {
        guard let id = snapshotID, let uid = ownerUID else { return }
        SnapshotStore.shared.recordError(error.rawValue, identifier: id, uid: uid)
    }

    private func reportAdapterError(_ error: WireGuardAdapterError) -> PacketTunnelProviderError {
        switch error {
        case .cannotLocateTunnelFileDescriptor:
            wg_log(.error, staticMessage: "Could not determine tunnel file descriptor")
            return .couldNotDetermineFileDescriptor
        case .dnsResolution:
            wg_log(.error, staticMessage: "WireGuard endpoint DNS resolution failed")
            return .dnsResolutionFailure
        case .setNetworkSettings:
            wg_log(.error, staticMessage: "Could not apply tunnel network settings")
            return .couldNotSetNetworkSettings
        case .startWireGuardBackend:
            wg_log(.error, staticMessage: "Could not start WireGuard backend")
            return .couldNotStartBackend
        case .invalidState:
            wg_log(.error, staticMessage: "Unexpected WireGuard adapter state")
            return .couldNotStartBackend
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.generation += 1
            self.safetyCancellation?.cancel()
            self.proxyReady = false
            if ["checking", "rolling-back"].contains(self.safetyReport.result) {
                self.safetyReport.result = "cancelled"
                self.safetyReport.stage = "启动已取消"
                self.saveSafetyReport()
            }
            self.finishStart(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
            self.proxyRuntime.stop()
            self.adapter.stop { error in
                if error != nil { wg_log(.error, staticMessage: "WireGuard adapter stop returned an error") }
                completionHandler()
                // A system extension also hosts XPC; do not exit the daemon on stop.
            }
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let completion = completionHandler else { return }
        if messageData.count == 1 && messageData[0] == 0 {
            adapter.getRuntimeConfiguration { completion($0?.data(using: .utf8)) }
        } else {
            completion(nil)
        }
    }
}

private final class SafetyCancellation {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func performActiveMutation(_ operation: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try operation()
    }
}

extension WireGuardLogLevel {
    var osLogLevel: OSLogType {
        switch self {
        case .verbose: return .debug
        case .error: return .error
        }
    }
}
