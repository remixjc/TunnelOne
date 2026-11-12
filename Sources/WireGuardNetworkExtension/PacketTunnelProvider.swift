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
    private var proxyEnvironment: MacSystemProxySafetyEnvironment?
    private var sourcePreparation: SystemProxySafetyStart.Preparation?
    private var proxyChangeWork: DispatchWorkItem?
    private var proxyUpdateInFlight = false
    private var proxyUpdatePending = false
    private var checkDefaultRoute = false
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
        checkDefaultRoute = tunnel.peers.contains { peer in
            peer.allowedIPs.contains { $0.stringRepresentation == "0.0.0.0/0" }
        }
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
                    let environment = MacSystemProxySafetyEnvironment(
                        performActiveMutation: { try cancellation.performActiveMutation($0) },
                        isCancelled: { cancellation.isCancelled }, directProbe: {
                            TunnelConnectivityProbe.run(provider: self, isCancelled: { cancellation.isCancelled })
                        })
                    let policy = SystemProxySafetyStart(environment: environment)
                    let initial = try policy.prepare()
                    let preparation = SystemProxySafetyStart.Preparation(sourceService: initial.sourceService,
                        sourceInterface: initial.sourceInterface, proxy: initial.proxy,
                        observedSource: try environment.sourceProxy(service: initial.sourceService))
                    DispatchQueue.main.async {
                        guard generation == self.generation, !cancellation.isCancelled else { return }
                        self.proxyEnvironment = environment
                        self.sourcePreparation = preparation
                        self.safetyReport.proxySummary = preparation.proxy.summary
                        self.safetyReport.proxyApplied = preparation.proxy.hasProxy
                        self.safetyReport.stage = "启动 WireGuard"
                        self.saveSafetyReport()
                        self.startAdapter(tunnel, snapshot: snapshot, uid: uid, gid: gid,
                                          generation: generation, policy: policy, preparation: preparation)
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
                              policy: SystemProxySafetyStart? = nil, preparation: SystemProxySafetyStart.Preparation? = nil) {
        let proxy = snapshot.proxy
        if let preparation = preparation { adapter.proxySettings = SystemProxyNetworkSettings.make(preparation.proxy) }
        else { adapter.proxySettings = ProxyRuntime.networkSettings(for: proxy) }
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

    private func verifySafety(_ policy: SystemProxySafetyStart, preparation: SystemProxySafetyStart.Preparation, generation: Int) {
        let interface = adapter.interfaceName ?? ""
        let checkDirect = checkDefaultRoute
        guard let cancellation = safetyCancellation else { return }
        DispatchQueue.global(qos: .utility).async {
            do {
                let report = try policy.verify(preparation, interface: interface, checkDirect: checkDirect,
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
                    if ["connected-and-checked", "connected-without-proxy"].contains(report.result) {
                        self.proxyReady = report.proxyApplied == true
                        do {
                            try self.proxyEnvironment?.observeChanges { [weak self] in self?.scheduleProxyRefresh() }
                        } catch {
                            self.rollbackSafety(error, generation: generation)
                            return
                        }
                        self.saveSafetyReport()
                        // Reconcile changes that happened while the initial
                        // network checks ran, before the observer was installed.
                        self.scheduleProxyRefresh()
                        wg_log(.info, staticMessage: "WireGuard and inherited system proxy verification completed")
                    } else {
                        self.rollbackSafety(SystemProxySafetyStart.Failure(report.reason ?? "连通检查失败。"),
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

    private func stopProxyObservation() {
        proxyChangeWork?.cancel()
        proxyChangeWork = nil
        proxyEnvironment?.stopObserving()
        sourcePreparation = nil
        proxyUpdateInFlight = false
        proxyUpdatePending = false
    }

    private func scheduleProxyRefresh() {
        guard sourcePreparation != nil, safetyCancellation?.isCancelled == false else { return }
        if proxyUpdateInFlight { proxyUpdatePending = true; return }
        proxyChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshProxySource() }
        proxyChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    private func finishProxyRefresh() {
        proxyUpdateInFlight = false
        if proxyUpdatePending { proxyUpdatePending = false; scheduleProxyRefresh() }
    }

    private func refreshProxySource() {
        guard let environment = proxyEnvironment, let previous = sourcePreparation,
              let cancellation = safetyCancellation, !cancellation.isCancelled else { return }
        let generation = self.generation
        proxyUpdateInFlight = true
        DispatchQueue.global(qos: .utility).async {
            do {
                let candidate = try environment.refreshedSource(previous)
                guard !cancellation.isCancelled else { return }
                if candidate.proxy == previous.proxy,
                   (try? SystemProxySnapshot(dictionary: environment.effectiveProxy())) == candidate.proxy {
                    DispatchQueue.main.async {
                        guard generation == self.generation else { return }
                        self.sourcePreparation = candidate
                        self.finishProxyRefresh()
                    }
                    return
                }
                if candidate.proxy.hasProxy {
                    let check = try environment.probe(snapshot: candidate.proxy, useSystem: false)
                    guard check.ok else { throw SystemProxySafetyStart.Failure("更新后的系统代理不可用：" + check.failureDescription) }
                }
                DispatchQueue.main.async {
                    guard generation == self.generation, !cancellation.isCancelled else { return }
                    self.safetyReport.result = "checking"
                    self.safetyReport.stage = "系统代理已变化，正在更新本次隧道"
                    self.saveSafetyReport()
                    self.adapter.updateProxySettings(SystemProxyNetworkSettings.make(candidate.proxy)) { error in
                        DispatchQueue.main.async {
                            guard generation == self.generation, !cancellation.isCancelled else { return }
                            if let error = error { self.rollbackSafety(error, generation: generation); return }
                            let interface = self.adapter.interfaceName ?? ""
                            DispatchQueue.global(qos: .utility).async {
                                do {
                                    let policy = SystemProxySafetyStart(environment: environment)
                                    let updated = try policy.verify(candidate, interface: interface, checkDirect: false,
                                                                    isCancelled: { cancellation.isCancelled })
                                    DispatchQueue.main.async {
                                        guard generation == self.generation, !cancellation.isCancelled else { return }
                                        var report = updated
                                        report.activationAttemptID = self.safetyReport.activationAttemptID
                                        self.safetyReport = report
                                        if report.result == "failed" {
                                            self.rollbackSafety(SystemProxySafetyStart.Failure(report.reason ?? "系统代理更新验证失败。"), generation: generation)
                                            return
                                        }
                                        self.sourcePreparation = candidate
                                        self.proxyReady = candidate.proxy.hasProxy
                                        self.saveSafetyReport()
                                        self.finishProxyRefresh()
                                    }
                                } catch {
                                    DispatchQueue.main.async {
                                        guard generation == self.generation else { return }
                                        self.rollbackSafety(error, generation: generation)
                                    }
                                }
                            }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard generation == self.generation else { return }
                    if error is MacSystemProxySafetyEnvironment.NetworkUnavailable {
                        self.finishProxyRefresh() // The next network notification retries after recovery.
                    } else { self.rollbackSafety(error, generation: generation) }
                }
            }
        }
    }

    private func rollbackSafety(_ error: Error, generation: Int) {
        stopProxyObservation()
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
                self.safetyReport.stage = adapterError == nil ? "已自动断开本次 WireGuard，保留原有系统代理" : "自动断开失败，请手动断开 WireGuard"
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
            self.stopProxyObservation()
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
