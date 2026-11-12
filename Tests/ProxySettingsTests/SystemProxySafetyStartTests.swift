import XCTest
@testable import TunnelOnePolicy

final class SystemProxySafetyStartTests: XCTestCase {
    final class Environment: SystemProxySafetyEnvironment {
        var service = "physical", interface = "en0", owner = "utun12"
        var effective: [String: Any] = ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 17897,
                                       "ExceptionsList": ["*.internal"]]
        var writes: [(String, [String: Any])] = []
        var applyWrites = true, connected = true
        var preflightOK = true, directOK = true, proxyOK = true
        var attempted: [String] = []
        var pauses = 0, connectedAfterPauses = 0
        var onPause: (() -> Void)?
        let lock = NSLock()
        func primaryNetwork() throws -> (service: String, interface: String) { (service, interface) }
        func effectiveProxy() throws -> [String: Any] { effective }
        func tunnelService(interface: String) throws -> String {
            guard interface == owner else { throw SystemProxySafetyStart.Failure("Wrong tunnel owner") }
            return "temporary-vpn"
        }
        func setProxyDictionary(_ value: [String: Any], service: String) throws {
            writes.append((service, value)); if applyWrites { effective = value }
        }
        func tunnelConnected(interface: String) throws -> Bool { connected && pauses >= connectedAfterPauses }
        func probe(snapshot: SystemProxySnapshot?, useSystem: Bool) throws -> SafetyProbe {
            let phase = snapshot == nil ? "direct" : useSystem ? "system" : "preflight"
            lock.lock(); attempted.append(phase); lock.unlock()
            let ok = phase == "direct" ? directOK : phase == "system" ? proxyOK : preflightOK
            return SafetyProbe(name: phase, ok: ok, http: ok ? "204" : "000", detail: ok ? nil : "Fixture failure")
        }
        func pause() { pauses += 1; onPause?() }
        func connect() { service = "temporary-vpn"; interface = "utun12"; effective = [:]; attempted = [] }
    }

    func testIndependentProtocolsAndPortsNeedNoClientConfiguration() throws {
        let env = Environment()
        let preparation = try SystemProxySafetyStart(environment: env).prepare()
        XCTAssertNil(preparation.proxy.http)
        XCTAssertNil(preparation.proxy.socks)
        XCTAssertEqual(preparation.proxy.https?.port, 17897)
        XCTAssertEqual(env.attempted, ["preflight"])
    }

    func testPreflightFailureDoesNotCreateOrWriteTunnelSettings() {
        let env = Environment(); env.preflightOK = false
        XCTAssertThrowsError(try SystemProxySafetyStart(environment: env).prepare())
        XCTAssertTrue(env.writes.isEmpty)
    }

    func testOnlyThisTunnelServiceIsWrittenAndEffectiveSystemProbeRuns() throws {
        let env = Environment(); let policy = SystemProxySafetyStart(environment: env)
        let preparation = try policy.prepare(); env.connect()
        let report = try policy.verify(preparation, interface: "utun12")
        XCTAssertEqual(env.writes.count, 1)
        XCTAssertEqual(env.writes.first?.0, "temporary-vpn")
        XCTAssertEqual(env.writes.first?.1["ExceptionsList"] as? [String], ["*.internal"])
        XCTAssertEqual(report.result, "connected-and-checked")
        XCTAssertEqual(report.proxyApplied, true)
        XCTAssertEqual(Set(env.attempted), ["system", "direct"])
    }

    func testNoProxyMeansWireGuardOnlyWithoutAProxyProbe() throws {
        let env = Environment(); env.effective = [:]
        let policy = SystemProxySafetyStart(environment: env); let preparation = try policy.prepare()
        XCTAssertTrue(env.attempted.isEmpty)
        env.connect()
        let report = try policy.verify(preparation, interface: "utun12", checkDirect: false)
        XCTAssertEqual(report.result, "connected-without-proxy")
        XCTAssertEqual(report.proxyApplied, false)
        XCTAssertTrue(report.checks.isEmpty)
        XCTAssertTrue(env.attempted.isEmpty)
    }

    func testSplitTunnelDoesNotRequireDefaultRouteOrPublicDirectProbe() throws {
        let env = Environment(); let policy = SystemProxySafetyStart(environment: env)
        let preparation = try policy.prepare(); env.connect()
        let report = try policy.verify(preparation, interface: "utun12", checkDirect: false)
        XCTAssertEqual(report.result, "connected-and-checked")
        XCTAssertEqual(env.attempted, ["system"])
    }

    func testWrongTunnelServiceAndFailedEffectiveSyncCannotProbe() throws {
        for wrongOwner in [false, true] {
            let env = Environment(); let policy = SystemProxySafetyStart(environment: env)
            let preparation = try policy.prepare(); env.connect()
            if wrongOwner { env.owner = "utun99" } else { env.applyWrites = false }
            XCTAssertThrowsError(try policy.verify(preparation, interface: "utun12"))
            XCTAssertTrue(env.attempted.isEmpty)
        }
    }

    func testEitherConnectivityFailureCannotReportSuccess() throws {
        for direct in [false, true] {
            let env = Environment(); let policy = SystemProxySafetyStart(environment: env)
            let preparation = try policy.prepare(); env.connect()
            if direct { env.directOK = false } else { env.proxyOK = false }
            let report = try policy.verify(preparation, interface: "utun12")
            XCTAssertEqual(report.result, "failed")
            XCTAssertNotNil(report.reason)
            XCTAssertEqual(env.attempted.count, 2)
        }
    }

    func testWaitsForConnectedAndSettlingAndCancellationPreventsMutation() throws {
        let env = Environment(); let policy = SystemProxySafetyStart(environment: env)
        let preparation = try policy.prepare(); env.connect(); env.connectedAfterPauses = 3
        env.onPause = { XCTAssertTrue(env.writes.isEmpty); XCTAssertTrue(env.attempted.isEmpty) }
        _ = try policy.verify(preparation, interface: "utun12")
        XCTAssertEqual(env.pauses, 7)
        env.writes = []; env.attempted = []
        XCTAssertThrowsError(try policy.verify(preparation, interface: "utun12", isCancelled: { true }))
        XCTAssertTrue(env.writes.isEmpty)
        XCTAssertTrue(env.attempted.isEmpty)
    }

    func testConnectedTimeoutAndSettlingDisconnectCannotWrite() throws {
        for disconnect in [false, true] {
            let env = Environment(); let policy = SystemProxySafetyStart(environment: env)
            let preparation = try policy.prepare(); env.connect()
            if disconnect { env.onPause = { env.connected = false } } else { env.connected = false }
            XCTAssertThrowsError(try policy.verify(preparation, interface: "utun12"))
            XCTAssertTrue(env.writes.isEmpty)
            XCTAssertTrue(env.attempted.isEmpty)
        }
    }

    func testExistingTunnelIsNotMisreadAsProxySource() {
        let env = Environment(); env.interface = "utun7"
        XCTAssertThrowsError(try SystemProxySafetyStart(environment: env).prepare())
        XCTAssertTrue(env.attempted.isEmpty)
    }

    func testOldReportsStillDecodeWithoutNewProxyMetadata() throws {
        let old = Data(#"{"time":"fixture","stage":"旧报告","result":"failed","checks":[{"name":"国内直连","ok":false,"http":"000"}]}"#.utf8)
        let report = try JSONDecoder().decode(SafetyStartReport.self, from: old)
        XCTAssertNil(report.proxyApplied)
        XCTAssertNil(report.proxySummary)
        XCTAssertNil(report.checks.first?.exitCode)
    }
}
