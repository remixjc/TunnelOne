import XCTest
@testable import TunnelOnePolicy

final class ClashSafetyStartTests: XCTestCase {
    final class Environment: ClashSafetyEnvironment {
        var app = "sysProxy:\n  enable: true\n"
        var core = "tun:\n  enable: false\nmixed-port: 7890\nmode: rule\n"
        var service = "physical", interface = "en0", route = "utun12"
        var effective = Environment.proxy
        var stateSource: [String: Any]?
        var setupSource: [String: Any]? = Environment.proxy
        var writes: [(String, [String: Any])] = []
        var applyWrites = true
        var directOK = true, proxyOK = true
        var attempted: [Bool] = []
        let lock = NSLock()
        static let proxy: [String: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890,
            "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 7890,
            "ExceptionsList": ["*.local"]
        ]
        func clashConfiguration() throws -> (app: String, core: String) { (app, core) }
        func primaryNetwork() throws -> (service: String, interface: String) { (service, interface) }
        func effectiveProxy() throws -> [String: Any] { effective }
        func proxyDictionary(key: String) throws -> [String: Any]? {
            key.hasPrefix("State:") ? stateSource : setupSource
        }
        func setProxyDictionary(_ value: [String: Any], service: String) throws {
            writes.append((service, value))
            if applyWrites { effective = value }
        }
        func ipv4RouteInterface() throws -> String { route }
        func probe(proxy: Bool) throws -> SafetyProbe {
            lock.lock(); attempted.append(proxy); lock.unlock()
            let ok = proxy ? proxyOK : directOK
            return SafetyProbe(name: proxy ? "国外代理" : "国内直连", ok: ok, http: ok ? (proxy ? "204" : "200") : "000")
        }
        func pause() {}
        func connect() { service = "temporary-vpn"; interface = "utun12"; effective = [:] }
    }

    func testDefaultToggleUsesExistingClashWithoutYAMLImport() throws {
        var settings = ProxySettings()
        settings.enabled = true
        XCTAssertEqual(settings.source, .external)
        XCTAssertEqual(settings.port, 7890)
        XCTAssertNoThrow(try settings.validate())
    }

    func testScopedWifiProxyDoesNotCountAsEffectiveGlobalProxy() {
        XCTAssertFalse(ClashSafetyStart.proxyMatches(["__SCOPED__": ["en0": Environment.proxy]]))
        var httpOnly = Environment.proxy
        httpOnly.removeValue(forKey: "SOCKSEnable")
        XCTAssertFalse(ClashSafetyStart.proxyMatches(httpOnly))
    }

    func testCopiesSetupFallbackOnlyIntoThisTunnelsTemporaryService() throws {
        let environment = Environment()
        let policy = ClashSafetyStart(environment: environment)
        let preparation = try policy.prepare()
        environment.connect()
        let report = try policy.verify(preparation, interface: "utun12")
        XCTAssertEqual(environment.writes.count, 1)
        XCTAssertEqual(environment.writes.first?.0, "temporary-vpn")
        XCTAssertEqual(environment.writes.first?.1["ExceptionsList"] as? [String], ["*.local"])
        XCTAssertEqual(report.result, "connected-and-checked")
        XCTAssertEqual(report.checks.map(\.http), ["200", "204"])
        XCTAssertEqual(report.proxySync, "copied-to-tunnel-state")
    }

    func testAlreadyEffectiveProxyNeedsNoWrite() throws {
        let environment = Environment()
        let policy = ClashSafetyStart(environment: environment)
        let preparation = try policy.prepare()
        environment.connect()
        environment.effective = Environment.proxy
        let report = try policy.verify(preparation, interface: "utun12")
        XCTAssertTrue(environment.writes.isEmpty)
        XCTAssertEqual(report.proxySync, "already-effective")
    }

    func testRejectsUnsafeClashSettingsBeforeAnyNetworkWrite() throws {
        for config in [
            "tun:\n  enable: true\nmixed-port: 7890\nmode: rule\n",
            "tun:\n  enable: false\nmixed-port: 7891\nmode: rule\n",
            "tun:\n  enable: false\nmixed-port: 7890\nmode: global\n"
        ] {
            let environment = Environment()
            environment.core = config
            XCTAssertThrowsError(try ClashSafetyStart(environment: environment).prepare())
            XCTAssertTrue(environment.writes.isEmpty)
            XCTAssertTrue(environment.attempted.isEmpty)
        }
    }

    func testRejectsOtherVPNAndMissingSource() throws {
        let environment = Environment()
        environment.interface = "utun5"
        XCTAssertThrowsError(try ClashSafetyStart(environment: environment).prepare())
        environment.interface = "en0"
        environment.setupSource = nil
        XCTAssertThrowsError(try ClashSafetyStart(environment: environment).prepare())
    }

    func testDoesNotWriteWhenRouteOrPrimaryNetworkBelongsToAnotherTunnel() throws {
        for wrongRoute in [false, true] {
            let environment = Environment()
            let policy = ClashSafetyStart(environment: environment)
            let preparation = try policy.prepare()
            environment.connect()
            if wrongRoute { environment.route = "utun99" } else { environment.interface = "utun99" }
            XCTAssertThrowsError(try policy.verify(preparation, interface: "utun12"))
            XCTAssertTrue(environment.writes.isEmpty)
        }
    }

    func testFailedEffectiveProxyStopsBeforeProbes() throws {
        let environment = Environment()
        let policy = ClashSafetyStart(environment: environment)
        let preparation = try policy.prepare()
        environment.connect()
        environment.applyWrites = false
        XCTAssertThrowsError(try policy.verify(preparation, interface: "utun12"))
        XCTAssertTrue(environment.attempted.isEmpty)
    }

    func testBothTargetsRunAndEitherFailureRequiresRollback() throws {
        for directFailure in [false, true] {
            let environment = Environment()
            let policy = ClashSafetyStart(environment: environment)
            let preparation = try policy.prepare()
            environment.connect()
            if directFailure { environment.directOK = false } else { environment.proxyOK = false }
            let report = try policy.verify(preparation, interface: "utun12")
            XCTAssertEqual(report.result, "failed")
            XCTAssertEqual(environment.attempted.sorted(by: { !$0 && $1 }), [false, true])
            XCTAssertNotNil(report.reason)
        }
    }

    func testCancellationCannotWriteOrReportSuccess() throws {
        let environment = Environment()
        let policy = ClashSafetyStart(environment: environment)
        let preparation = try policy.prepare()
        environment.connect()
        XCTAssertThrowsError(try policy.verify(preparation, interface: "utun12", isCancelled: { true }))
        XCTAssertTrue(environment.writes.isEmpty)
        XCTAssertTrue(environment.attempted.isEmpty)
    }

    func testCancellationImmediatelyBeforeProxySyncCannotWrite() throws {
        let environment = Environment()
        let policy = ClashSafetyStart(environment: environment)
        let preparation = try policy.prepare()
        environment.connect()
        var cancelled = false
        XCTAssertThrowsError(try policy.verify(preparation, interface: "utun12",
            isCancelled: { cancelled }, progress: { _ in cancelled = true }))
        XCTAssertTrue(environment.writes.isEmpty)
        XCTAssertTrue(environment.attempted.isEmpty)
    }
}
