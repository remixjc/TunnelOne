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
    private var pendingStart: ((Error?) -> Void)?
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
        let notifier = ErrorNotifier(activationAttemptId: options?["activationAttemptId"] as? String)
        Logger.configureGlobal(tagged: "NET", withFilePath: FileManager.logFileURL?.path)
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let tunnel = proto.asTunnelConfiguration() else {
            notifier.notify(.savedProtocolConfigurationIsInvalid)
            finishStart(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
            return
        }
        let proxy: ProxySettings
        do {
            proxy = try ProxySettings.decodeProviderValue(proto.providerConfiguration?[ProxySettings.configurationKey])
        } catch {
            wg_log(.error, staticMessage: "Invalid TunnelOne proxy settings; refusing activation")
            notifier.notify(.couldNotStartProxy)
            finishStart(error)
            return
        }
        adapter.proxySettings = ProxyRuntime.networkSettings(for: proxy)
        adapter.start(tunnelConfiguration: tunnel) { adapterError in
            DispatchQueue.main.async {
                guard generation == self.generation else { return }
                if let error = adapterError {
                    let mapped = self.reportAdapterError(error)
                    notifier.notify(mapped)
                    self.finishStart(mapped)
                    return
                }
                wg_log(.info, message: "WireGuard interface: \(self.adapter.interfaceName ?? "unknown")")
                self.proxyRuntime.start(proxy, interfaceName: self.adapter.interfaceName,
                                        onUnexpectedExit: { [weak self] in
                    DispatchQueue.main.async {
                        guard let self = self, generation == self.generation, self.proxyReady else { return }
                        self.proxyReady = false
                        wg_log(.error, staticMessage: "Proxy core exited unexpectedly; disconnecting tunnel")
                        self.cancelTunnelWithError(NSError(domain: "TunnelOne.Proxy", code: 2))
                    }
                }) { error in
                    DispatchQueue.main.async {
                        guard generation == self.generation else { return }
                        if let error = error {
                            notifier.notify(.couldNotStartProxy)
                            wg_log(.error, staticMessage: "Proxy startup failed; rolling back WireGuard")
                            self.proxyRuntime.stop()
                            self.adapter.stop { _ in
                                DispatchQueue.main.async {
                                    guard generation == self.generation else { return }
                                    self.finishStart(error)
                                }
                            }
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

    private func finishStart(_ error: Error?) {
        let completion = pendingStart
        pendingStart = nil
        completion?(error)
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
            self.proxyReady = false
            self.finishStart(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
            self.proxyRuntime.stop()
            self.adapter.stop { error in
                ErrorNotifier.removeLastErrorFile()
                if error != nil { wg_log(.error, staticMessage: "WireGuard adapter stop returned an error") }
                completionHandler()
                // Retain upstream workaround for Apple bug 32073323 / 47526107.
                // The launcher observes parent exit and reaps the core if needed.
                exit(0)
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

extension WireGuardLogLevel {
    var osLogLevel: OSLogType {
        switch self {
        case .verbose: return .debug
        case .error: return .error
        }
    }
}
