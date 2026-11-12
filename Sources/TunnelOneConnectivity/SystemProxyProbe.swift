// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if SWIFT_PACKAGE
import TunnelOnePolicy
#endif

/// URLSession uses CFNetwork's HTTP/HTTPS/SOCKS/PAC selection and bypass rules.
/// Preflight uses a captured dictionary; verification uses effective system
/// settings (nil), so an explicitly forced proxy cannot mask a sync failure.
enum SystemProxyProbe {
    static func run(snapshot: SystemProxySnapshot?, isCancelled: @escaping () -> Bool,
                    url: URL = URL(string: "https://www.google.com/generate_204")!,
                    timeout: TimeInterval = 9) -> SafetyProbe {
        Operation(snapshot: snapshot, url: url, timeout: timeout).run(isCancelled: isCancelled)
    }

    private final class Operation: NSObject, URLSessionDataDelegate {
        let configuration: URLSessionConfiguration
        let url: URL
        let timeout: TimeInterval
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var code = 0
        var completed = false
        var error: Error?
        var usedProxy: Bool?

        init(snapshot: SystemProxySnapshot?, url: URL, timeout: TimeInterval) {
            self.url = url
            self.timeout = timeout
            configuration = .ephemeral
            configuration.connectionProxyDictionary = snapshot?.dictionary
            configuration.timeoutIntervalForRequest = min(7, timeout)
            configuration.timeoutIntervalForResource = timeout
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
        }

        func run(isCancelled: () -> Bool) -> SafetyProbe {
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            session.dataTask(with: url).resume()
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while done.wait(timeout: .now() + 0.1) == .timedOut {
                if isCancelled() || ProcessInfo.processInfo.systemUptime >= deadline {
                    return SafetyProbe(name: "系统代理访问", ok: false, http: "000",
                                       detail: isCancelled() ? "代理检查已取消。" : "系统代理访问超时。",
                                       transport: "系统代理规则")
                }
            }
            lock.lock(); defer { lock.unlock() }
            let ok = (200..<400).contains(code)
            let detail: String?
            if code == 407 { detail = "系统代理要求认证，无法自动取得该用户的代理凭据。" }
            else if code != 0 && !ok { detail = "目标返回 HTTP \(code)。" }
            else if let error = error, code == 0 {
                let value = error as NSError
                detail = "系统代理请求失败（\(value.domain) \(value.code)）。"
            } else { detail = nil }
            let path = usedProxy.map { $0 ? "系统代理规则（代理）" : "系统代理规则（DIRECT）" } ?? "系统代理规则"
            return SafetyProbe(name: "系统代理访问", ok: ok, http: code == 0 ? "000" : String(code),
                               detail: detail, transport: path)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            lock.lock()
            code = (response as? HTTPURLResponse)?.statusCode ?? 0
            lock.unlock()
            completionHandler(.cancel) // The status is enough; never download a page body.
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            lock.lock(); code = response.statusCode; lock.unlock()
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didFinishCollecting metrics: URLSessionTaskMetrics) {
            lock.lock()
            usedProxy = metrics.transactionMetrics.last?.isProxyConnection
            lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            self.error = error
            completed = true
            lock.unlock()
            done.signal()
        }
    }
}
