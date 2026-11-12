import XCTest
import Network
import NetworkExtension
import TunnelOnePolicy
@testable import TunnelOneConnectivity

final class SystemProxyTests: XCTestCase {
    func testNativeSettingsPreserveIndependentProtocolsAndPAC() throws {
        let snapshot = try SystemProxySnapshot(dictionary: [
            "HTTPEnable": 1, "HTTPProxy": "proxy.example", "HTTPPort": 8081,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7897,
            "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 1080,
            "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://pac.example/script",
            "ExceptionsList": ["*.internal"], "ExcludeSimpleHostnames": 0
        ])
        let native = try XCTUnwrap(SystemProxyNetworkSettings.make(snapshot))
        XCTAssertEqual(native.httpServer?.port, 8081)
        XCTAssertEqual(native.httpsServer?.port, 7897)
        XCTAssertEqual(native.proxyAutoConfigurationURL, snapshot.pacURL)
        XCTAssertEqual(native.exceptionList, ["*.internal"])
        XCTAssertFalse(native.excludeSimpleHostnames)
        let socksOnly = try SystemProxySnapshot(dictionary: ["SOCKSEnable": 1, "SOCKSProxy": "::1", "SOCKSPort": 1080])
        let socksNative = try XCTUnwrap(SystemProxyNetworkSettings.make(socksOnly))
        XCTAssertFalse(socksNative.httpEnabled)
        XCTAssertFalse(socksNative.httpsEnabled)
        XCTAssertNil(socksNative.httpServer) // Never disguise a SOCKS endpoint as HTTP.
        XCTAssertNil(SystemProxyNetworkSettings.make(try SystemProxySnapshot(dictionary: [:])))
    }

    func testHTTPAndSOCKSAndPACActuallyReachTheirConfiguredProxy() throws {
        for kind in ["HTTP", "SOCKS", "PAC"] {
            let server = try ProxyServer(socks: kind == "SOCKS")
            defer { server.stop() }
            let dictionary: [String: Any]
            if kind == "PAC" {
                dictionary = ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigJavaScript":
                    "function FindProxyForURL(url, host) { return 'PROXY 127.0.0.1:\(server.port)'; }"]
            } else {
                dictionary = [kind + "Enable": 1, kind + "Proxy": "127.0.0.1", kind + "Port": server.port]
            }
            let snapshot = try SystemProxySnapshot(dictionary: dictionary)
            let result = SystemProxyProbe.run(snapshot: snapshot, isCancelled: { false },
                url: URL(string: "http://destination.invalid/check")!, timeout: 3)
            XCTAssertTrue(result.ok, "\(kind): \(result.detail ?? result.http)")
            XCTAssertEqual(result.http, "204")
            XCTAssertTrue(server.receivedRequest, kind)
        }
    }

    func testBypassRuleIsHonoredAndUnavailableProxyCannotPass() throws {
        let server = try ProxyServer(socks: false)
        defer { server.stop() }
        let snapshot = try SystemProxySnapshot(dictionary: [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": server.port,
            "ExceptionsList": ["destination.invalid"]
        ])
        let result = SystemProxyProbe.run(snapshot: snapshot, isCancelled: { false },
            url: URL(string: "http://destination.invalid/check")!, timeout: 1)
        XCTAssertFalse(result.ok)
        XCTAssertFalse(server.receivedRequest)
        let cancelled = SystemProxyProbe.run(snapshot: snapshot, isCancelled: { true },
            url: URL(string: "http://destination.invalid/check")!, timeout: 1)
        XCTAssertFalse(cancelled.ok)
    }

    /// Local protocol fixtures deliberately use an unresolvable target. A
    /// direct fallback cannot pass; the proxy must receive and answer the request.
    final class ProxyServer {
        let listener: NWListener
        let queue = DispatchQueue(label: "ProxyTests.Server")
        let lock = NSLock()
        var connections: [NWConnection] = []
        private var request = false
        var receivedRequest: Bool { lock.lock(); defer { lock.unlock() }; return request }
        var port: Int { Int(listener.port!.rawValue) }

        init(socks: Bool) throws {
            listener = try NWListener(using: .tcp, on: .any)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
                if case .failed = state { ready.signal() }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self = self else { return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                if socks { self.greet(connection) } else { self.readHTTP(connection) }
            }
            listener.start(queue: queue)
            guard ready.wait(timeout: .now() + 2) == .success,
                  let port = listener.port, port.rawValue != 0 else {
                throw NSError(domain: "ProxyFixture", code: 1)
            }
        }

        func read(_ connection: NWConnection, count: Int, next: @escaping (Data) -> Void) {
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, _ in
                guard let data = data, data.count == count else { connection.cancel(); return }
                next(data)
            }
        }
        func greet(_ connection: NWConnection) {
            read(connection, count: 2) { header in
                guard header[0] == 5 else { connection.cancel(); return }
                self.read(connection, count: Int(header[1])) { _ in
                    connection.send(content: Data([5, 0]), completion: .contentProcessed { _ in
                        self.read(connection, count: 4) { header in
                            if header[3] == 3 {
                                self.read(connection, count: 1) { size in self.connectSOCKS(connection, count: Int(size[0]) + 2) }
                            } else { self.connectSOCKS(connection, count: header[3] == 1 ? 6 : 18) }
                        }
                    })
                }
            }
        }
        func connectSOCKS(_ connection: NWConnection, count: Int) {
            read(connection, count: count) { _ in
                connection.send(content: Data([5, 0, 0, 1, 127, 0, 0, 1, 0, 80]), completion: .contentProcessed { _ in
                    self.readHTTP(connection)
                })
            }
        }
        func readHTTP(_ connection: NWConnection, buffer: Data = Data()) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                guard let data = data, !data.isEmpty else { connection.cancel(); return }
                let head = buffer + data
                guard head.count <= 16384 else { connection.cancel(); return }
                guard head.range(of: Data("\r\n\r\n".utf8)) != nil else { self.readHTTP(connection, buffer: head); return }
                self.lock.lock(); self.request = true; self.lock.unlock()
                connection.send(content: Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        func stop() { queue.sync { listener.cancel(); connections.forEach { $0.cancel() } } }
    }
}
