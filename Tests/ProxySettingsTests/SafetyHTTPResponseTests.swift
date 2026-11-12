import XCTest
@testable import TunnelOnePolicy

final class SafetyHTTPResponseTests: XCTestCase {
    func testWaitsForCompleteResponseHeadAndIgnoresBinaryBody() throws {
        var bytes = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n".utf8)
        XCTAssertNil(try SafetyHTTPResponse.status(in: bytes))
        bytes.append(Data("\r\n".utf8))
        bytes.append(contentsOf: [0xff, 0xfe])
        XCTAssertEqual(try SafetyHTTPResponse.status(in: bytes), 200)
    }

    func testInterimResponsesAndRedirectAreNotReportedAsFailureOrFollowed() throws {
        let bytes = Data("HTTP/1.1 103 Early Hints\r\nLink: </x>\r\n\r\nHTTP/1.1 302 Found\r\nLocation: https://example.com/\r\n\r\n".utf8)
        XCTAssertEqual(try SafetyHTTPResponse.status(in: bytes), 302)
        XCTAssertNil(try SafetyHTTPResponse.status(in: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)))
    }

    func testRejectsInvalidAndOversizedResponses() throws {
        for line in ["HTTP/2 200 OK", "garbage", "HTTP/1.1 999 Unknown", "HTTP/1.1 101 Switching Protocols"] {
            XCTAssertThrowsError(try SafetyHTTPResponse.status(in: Data((line + "\r\n\r\n").utf8)))
        }
        XCTAssertThrowsError(try SafetyHTTPResponse.status(in: Data(repeating: 65, count: 16385)))
        XCTAssertEqual(try SafetyHTTPResponse.status(in: Data("HTTP/1.0 503 Unavailable\r\n\r\n".utf8)), 503)
    }

    func testNativeFailureDoesNotPretendToBeCurlFailureAndRetainsTransport() throws {
        let probe = SafetyProbe(name: "国内直连", ok: false, http: "000",
                                detail: "隧道内 TLS 错误", transport: "WireGuard 隧道内 HTTPS")
        XCTAssertFalse(probe.failureDescription.contains("curl"))
        XCTAssertTrue(probe.failureDescription.contains("TLS 错误"))
        let roundTrip = try JSONDecoder().decode(SafetyProbe.self, from: JSONEncoder().encode(probe))
        XCTAssertEqual(roundTrip.transport, probe.transport)
    }
}
