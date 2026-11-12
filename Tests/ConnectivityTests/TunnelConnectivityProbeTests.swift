import XCTest
import Network
import NetworkExtension
import TunnelOnePolicy
@testable import TunnelOneConnectivity

final class TunnelConnectivityProbeTests: XCTestCase {
    func testDirectTLSRequiresSelectedInterfaceAndBypassesSystemProxy() throws {
        let monitor = NWPathMonitor()
        let ready = expectation(description: "Interface snapshot")
        var interface: Network.NWInterface?
        monitor.pathUpdateHandler = { path in
            interface = path.availableInterfaces.first
            ready.fulfill()
        }
        monitor.start(queue: DispatchQueue(label: "ProbeTests.Interfaces"))
        defer { monitor.cancel() }
        wait(for: [ready], timeout: 2)
        let selected = try XCTUnwrap(interface)
        let parameters = TunnelConnectivityProbe.directParameters(interface: selected)
        XCTAssertEqual(parameters.requiredInterface, selected)
        XCTAssertTrue(parameters.preferNoProxies)
        XCTAssertTrue(parameters.defaultProtocolStack.applicationProtocols.contains { $0 is NWProtocolTLS.Options })
    }

    final class Connection: ProbeTCPConnection {
        var state: NWTCPConnectionState = .connected
        var error: Error?
        var writeError: Error?
        var readError: Error?
        var fragments: [Data] = []
        var request: Data?
        var cancelled = false
        var hang = false
        func write(_ data: Data, completionHandler: @escaping (Error?) -> Void) {
            request = data
            completionHandler(writeError)
        }
        func readMinimumLength(_ minimum: Int, maximumLength maximum: Int,
                               completionHandler: @escaping (Data?, Error?) -> Void) {
            if hang { return }
            completionHandler(fragments.isEmpty ? nil : fragments.removeFirst(), readError)
        }
        func cancel() { cancelled = true }
    }

    func run(_ connection: Connection, cancelled: @escaping () -> Bool = { false }) -> TunnelOnePolicy.SafetyProbe {
        TunnelConnectivityProbe.Operation(connection: connection, isCancelled: cancelled,
                                          connectTimeout: 0.04, responseTimeout: 0.08).run()
    }

    func testTLSConnectionSendsDirectRequestAndParsesFragmentedHTTP() {
        let connection = Connection()
        connection.fragments = [Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r".utf8), Data("\n\r\nbody".utf8)]
        let result = run(connection)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.http, "200")
        XCTAssertEqual(result.transport, "WireGuard 隧道内 HTTPS")
        let request = String(data: connection.request!, encoding: .utf8)!
        XCTAssertTrue(request.hasPrefix("GET / HTTP/1.1\r\nHost: www.baidu.com\r\n"))
        XCTAssertFalse(request.contains("CONNECT "))
        XCTAssertTrue(connection.cancelled)
    }

    func testHTTPFailureAndTruncatedResponseCannotSucceed() {
        for response in ["HTTP/1.1 503 Unavailable\r\n\r\n", "HTTP/1.1 200"] {
            let connection = Connection()
            connection.fragments = [Data(response.utf8)]
            let result = run(connection)
            XCTAssertFalse(result.ok)
            XCTAssertNotNil(result.detail)
            XCTAssertTrue(connection.cancelled)
        }
    }

    func testTLSWriteAndReadErrorsPreserveDomainAndCode() {
        for phase in ["connect", "write", "read"] {
            let connection = Connection()
            let error = NSError(domain: "ProbeTLS", code: -9807,
                                userInfo: [NSLocalizedDescriptionKey: "Certificate failed"])
            if phase == "connect" { connection.state = .disconnected; connection.error = error }
            if phase == "write" { connection.writeError = error }
            if phase == "read" { connection.readError = error }
            let result = run(connection)
            XCTAssertFalse(result.ok)
            XCTAssertTrue(result.detail?.contains("ProbeTLS -9807") == true)
            XCTAssertNil(result.exitCode)
            XCTAssertTrue(connection.cancelled)
        }
    }

    func testCancellationAndBothDeadlinesCancelTheConnection() {
        for phase in ["cancel", "connect", "response"] {
            let connection = Connection()
            if phase == "connect" { connection.state = .connecting }
            if phase == "response" { connection.hang = true }
            let result = run(connection, cancelled: { phase == "cancel" })
            XCTAssertFalse(result.ok)
            XCTAssertTrue(connection.cancelled)
            if phase == "response" { XCTAssertNotNil(connection.request) }
            else { XCTAssertNil(connection.request) }
        }
    }
}
