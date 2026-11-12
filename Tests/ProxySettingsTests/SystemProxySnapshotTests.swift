import XCTest
@testable import TunnelOnePolicy

final class SystemProxySnapshotTests: XCTestCase {
    func testSeparateEndpointsLowPortsIPv6AndBypassRulesRoundTrip() throws {
        let snapshot = try SystemProxySnapshot(dictionary: [
            "HTTPEnable": 1, "HTTPProxy": "proxy.example", "HTTPPort": 80,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7897,
            "SOCKSEnable": 1, "SOCKSProxy": "::1", "SOCKSPort": 1080,
            "ExceptionsList": ["*.internal", "192.168.0.0/16"], "ExcludeSimpleHostnames": 1
        ])
        XCTAssertEqual(snapshot.http?.port, 80)
        XCTAssertEqual(snapshot.https?.port, 7897)
        XCTAssertEqual(snapshot.socks?.description, "[::1]:1080")
        XCTAssertEqual(try SystemProxySnapshot(dictionary: snapshot.dictionary), snapshot)
        XCTAssertEqual(snapshot.dictionary["ExceptionsList"] as? [String], ["*.internal", "192.168.0.0/16"])
    }

    func testDisabledStaleEndpointsAndScopedProxiesNeverEnableInheritance() throws {
        let snapshot = try SystemProxySnapshot(dictionary: [
            "HTTPEnable": 0, "HTTPProxy": "stale.example", "HTTPPort": 7890,
            "__SCOPED__": ["en0": ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7897]]
        ])
        XCTAssertFalse(snapshot.hasProxy)
        XCTAssertNil(snapshot.dictionary["HTTPProxy"])
        XCTAssertNil(snapshot.dictionary["__SCOPED__"])
    }

    func testPACPreservedWithoutExposingURLOrScriptInSummary() throws {
        for dictionary: [String: Any] in [
            ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://pac.example/secret?token=private"],
            ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigJavaScript": "function FindProxyForURL(u,h){return 'SOCKS5 localhost:1080';}"]
        ] {
            let snapshot = try SystemProxySnapshot(dictionary: dictionary)
            XCTAssertTrue(snapshot.hasProxy)
            XCTAssertEqual(snapshot.summary, "PAC 自动代理")
            XCTAssertEqual(try SystemProxySnapshot(dictionary: snapshot.dictionary), snapshot)
        }
    }

    func testMalformedEnabledProxyAndUnsupportedDiscoveryFailExplicitly() {
        for dictionary: [String: Any] in [
            ["HTTPEnable": 1],
            ["SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 65536],
            ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 1080.5],
            ["HTTPEnable": 1, "HTTPProxy": "user:pass@proxy", "HTTPPort": 80],
            ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "file:///private/pac.js"],
            ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://user:secret@pac.example/x"],
            ["ProxyAutoDiscoveryEnable": 1]
        ] { XCTAssertThrowsError(try SystemProxySnapshot(dictionary: dictionary)) }
    }
}
