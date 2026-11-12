// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import TunnelOnePolicy
@testable import TunnelOneStore

final class SnapshotStoreTests: XCTestCase {
    private var base: URL!
    private var store: SnapshotStore!
    private var uid: uid_t { getuid() }

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        store = SnapshotStore(root: base.appendingPathComponent("Configurations"), owner: uid)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }

    private func snapshot() -> SystemExtensionConfiguration {
        SystemExtensionConfiguration(wireGuard: "[Interface]\nPrivateKey = test-fixture", proxy: ProxySettings(), profile: nil)
    }

    func testImmutableSnapshotsArePrivateAndIsolatedByUser() throws {
        let value = snapshot()
        try store.save(value, uid: uid)
        XCTAssertEqual(try store.load(value.identifier, uid: uid).wireGuard, value.wireGuard)
        XCTAssertThrowsError(try store.save(value, uid: uid))
        XCTAssertThrowsError(try store.load(value.identifier, uid: uid + 1))
        let directory = base.appendingPathComponent("Configurations/\(uid)")
        let path = directory.appendingPathComponent(value.identifier + ".json")
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        store.recordError("couldNotStartProxy", identifier: value.identifier, uid: uid)
        XCTAssertEqual(store.lastError(value.identifier, uid: uid), "couldNotStartProxy")
        XCTAssertNil(store.lastError(value.identifier, uid: uid + 1))
        try store.remove(value.identifier, uid: uid)
        XCTAssertThrowsError(try store.load(value.identifier, uid: uid))
        XCTAssertNil(store.lastError(value.identifier, uid: uid))
    }

    func testPathTraversalAndSymlinksAreRejected() throws {
        XCTAssertThrowsError(try store.load("../secret", uid: uid))
        XCTAssertThrowsError(try store.save(snapshot(), uid: 0))
        let root = base.appendingPathComponent("Configurations")
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: base)
        XCTAssertThrowsError(try store.save(snapshot(), uid: uid))
    }

    func testTamperedPermissionsAndIdentityAreRejected() throws {
        let value = snapshot()
        try store.save(value, uid: uid)
        let path = base.appendingPathComponent("Configurations/\(uid)/\(value.identifier).json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        XCTAssertThrowsError(try store.load(value.identifier, uid: uid))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        try JSONEncoder().encode(snapshot()).write(to: path)
        XCTAssertThrowsError(try store.load(value.identifier, uid: uid))
    }

    func testBuiltInProfileMustBeBoundedAndPresent() throws {
        var proxy = ProxySettings()
        proxy.enabled = true
        proxy.source = .builtIn
        proxy.profileID = UUID().uuidString
        XCTAssertThrowsError(try SystemExtensionConfiguration(wireGuard: "config", proxy: proxy, profile: nil).validate())
        XCTAssertThrowsError(try SystemExtensionConfiguration(wireGuard: "config", proxy: proxy,
            profile: Data(repeating: 65, count: 5 * 1024 * 1024 + 1)).validate())
        try SystemExtensionConfiguration(wireGuard: "config", proxy: proxy, profile: Data("rules: []".utf8)).validate()
        XCTAssertThrowsError(try SystemExtensionConfiguration(identifier: "../../bad", wireGuard: "config",
            proxy: ProxySettings(), profile: nil).validate())
    }

    func testSafetyReportsRemainPrivateAndUserScoped() throws {
        let value = snapshot()
        try store.save(value, uid: uid)
        var report = SafetyStartReport()
        report.result = "failed"
        report.stage = "已自动断开本次 WireGuard"
        report.reason = "国内直连检查失败"
        report.checks = [SafetyProbe(name: "国内直连", ok: false, http: "000")]
        store.recordSafetyReport(report, identifier: value.identifier, uid: uid)
        let data = try XCTUnwrap(store.safetyReport(value.identifier, uid: uid))
        XCTAssertEqual(try JSONDecoder().decode(SafetyStartReport.self, from: data).reason, report.reason)
        XCTAssertNil(store.safetyReport(value.identifier, uid: uid + 1))
        let file = base.appendingPathComponent("Configurations/\(uid)/\(value.identifier).json.safety")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        try store.remove(value.identifier, uid: uid)
        XCTAssertNil(store.safetyReport(value.identifier, uid: uid))
    }
}
