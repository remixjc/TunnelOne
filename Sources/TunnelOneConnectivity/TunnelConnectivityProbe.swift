// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import NetworkExtension
#if SWIFT_PACKAGE
import TunnelOnePolicy
#endif

protocol ProbeTCPConnection {
    var state: NWTCPConnectionState { get }
    var error: Error? { get }
    func write(_ data: Data, completionHandler: @escaping (Error?) -> Void)
    func readMinimumLength(_ minimum: Int, maximumLength maximum: Int,
                           completionHandler: @escaping (Data?, Error?) -> Void)
    func cancel()
}

extension NWTCPConnection: ProbeTCPConnection {}

/// An ordinary provider socket (including a child curl) does not prove that
/// clients can use the VPN. Explicitly use the provider's through-tunnel API.
/// This compatibility API also supports our macOS 13 minimum deployment target.
enum TunnelConnectivityProbe {
    static func run(provider: NEPacketTunnelProvider, isCancelled: @escaping () -> Bool) -> SafetyProbe {
        let connection = provider.createTCPConnectionThroughTunnel(
            to: NWHostEndpoint(hostname: "www.baidu.com", port: "443"),
            enableTLS: true, tlsParameters: nil, delegate: nil)
        let operation = Operation(connection: connection, isCancelled: isCancelled)
        return operation.run()
    }

    final class Operation {
        let connection: ProbeTCPConnection
        let isCancelled: () -> Bool
        let connectTimeout: TimeInterval
        let responseTimeout: TimeInterval
        let queue = DispatchQueue(label: "TunnelOne.DirectConnectivity")
        let completed = DispatchSemaphore(value: 0)
        var result: SafetyProbe?
        var sent = false
        var head = Data()
        var poll: DispatchSourceTimer?
        let started = ProcessInfo.processInfo.systemUptime

        init(connection: ProbeTCPConnection, isCancelled: @escaping () -> Bool,
             connectTimeout: TimeInterval = 4, responseTimeout: TimeInterval = 7) {
            self.connection = connection
            self.isCancelled = isCancelled
            self.connectTimeout = connectTimeout
            self.responseTimeout = responseTimeout
        }

        func run() -> SafetyProbe {
            queue.async {
                let poll = DispatchSource.makeTimerSource(queue: self.queue)
                poll.schedule(deadline: .now(), repeating: min(0.1, self.connectTimeout / 4))
                poll.setEventHandler { [weak self] in self?.update() }
                self.poll = poll
                poll.resume()
            }
            completed.wait() // The timer bounds the operation to seven seconds.
            return queue.sync { result! }
        }

        func update() {
            guard result == nil else { return }
            if isCancelled() { finish(detail: "国内直连检查已取消。"); return }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if elapsed >= responseTimeout || (!sent && elapsed >= connectTimeout) {
                finish(detail: sent ? "隧道内 HTTPS 响应超时（7 秒）。" : "隧道内 DNS / TCP / TLS 建连超时（4 秒）。")
                return
            }
            switch connection.state {
            case .connected:
                guard !sent else { return }
                sent = true
                let request = Data("GET / HTTP/1.1\r\nHost: www.baidu.com\r\nUser-Agent: TunnelOne-SafetyCheck\r\nAccept: */*\r\nConnection: close\r\n\r\n".utf8)
                connection.write(request) { [weak self] error in
                    guard let self = self else { return }
                    self.queue.async {
                        guard self.result == nil else { return }
                        if let error = error { self.finish(error: error) }
                        else { self.read() }
                    }
                }
            case .disconnected, .cancelled, .invalid:
                finish(error: connection.error, detail: "隧道内 HTTPS 连接在收到 HTTP 响应前结束。")
            case .connecting, .waiting:
                break
            @unknown default:
                finish(detail: "隧道内 HTTPS 连接状态未知。")
            }
        }

        func read() {
            guard result == nil else { return }
            connection.readMinimumLength(1, maximumLength: 4096) { [weak self] data, error in
                guard let self = self else { return }
                self.queue.async {
                    guard self.result == nil else { return }
                    if let error = error { self.finish(error: error); return }
                    guard let data = data, !data.isEmpty else {
                        self.finish(detail: "隧道内 HTTPS 未返回完整 HTTP 响应头。")
                        return
                    }
                    self.head.append(data)
                    do {
                        if let code = try SafetyHTTPResponse.status(in: self.head) {
                            self.finish(http: code, detail: (200..<400).contains(code) ? nil : "百度返回 HTTP \(code)。")
                        } else { self.read() }
                    } catch { self.finish(detail: error.localizedDescription) }
                }
            }
        }

        func finish(http: Int = 0, error: Error? = nil, detail: String? = nil) {
            guard result == nil else { return }
            let description = error.map { error -> String in
                let error = error as NSError
                return "\(error.domain) \(error.code)：\(error.localizedDescription)"
            } ?? detail
            result = SafetyProbe(name: "国内直连", ok: (200..<400).contains(http),
                                 http: http == 0 ? "000" : String(http), detail: description,
                                 transport: "WireGuard 隧道内 HTTPS")
            poll?.cancel()
            poll = nil
            connection.cancel()
            completed.signal()
        }
    }
}
