import XCTest
@testable import TunnelOnePolicy

final class ProxySettingsTests: XCTestCase {
    func testNewImportDoesNotEnableProxy() throws {
        XCTAssertFalse(try ProxySettings.decode(nil).enabled)
    }

    func testEnabledBuiltInRequiresProfile() {
        var settings = ProxySettings()
        settings.enabled = true
        XCTAssertThrowsError(try settings.encoded())
    }

    func testRoundTripPreservesTunnelPreference() throws {
        var settings = ProxySettings()
        settings.enabled = true
        settings.profileID = UUID().uuidString
        settings.port = 17891
        XCTAssertEqual(try ProxySettings.decode(settings.encoded()), settings)
    }

    func testUnsafeProfileAndPortAreRejected() {
        var settings = ProxySettings()
        settings.profileID = "../secrets"
        XCTAssertThrowsError(try settings.validate())
        settings.profileID = nil
        settings.port = 0
        XCTAssertThrowsError(try settings.validate())
    }

    func testExternalProxyNeedsNoBuiltInProfile() throws {
        var settings = ProxySettings()
        settings.enabled = true
        settings.source = .external
        settings.port = 7890
        XCTAssertNoThrow(try settings.encoded())
        settings.host = "http://127.0.0.1"
        XCTAssertThrowsError(try settings.validate())
    }

    func testCorruptDataDoesNotSilentlyDisableProxy() {
        XCTAssertThrowsError(try ProxySettings.decode(Data("broken".utf8)))
        XCTAssertThrowsError(try ProxySettings.decodeProviderValue("broken"))
        XCTAssertThrowsError(try ProxySettings.decodeProviderValue(["enabled": true]))
    }
}
