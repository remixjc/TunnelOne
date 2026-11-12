// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Only the bounded HTTP/1.x response head is needed for a connectivity check.
/// No redirect is followed, matching the original curl command's status rule.
public enum SafetyHTTPResponse {
    public static let maximumHeadSize = 16 * 1024

    public static func status(in data: Data) throws -> Int? {
        guard data.count <= maximumHeadSize + 4096 else {
            throw SystemProxySafetyStart.Failure("国内直连 HTTP 响应头超过 16 KiB。")
        }
        let delimiter = Data([13, 10, 13, 10])
        var remaining = data
        while let end = remaining.range(of: delimiter) {
            guard end.upperBound - remaining.startIndex <= maximumHeadSize,
                  let lineEnd = remaining.range(of: Data([13, 10])),
                  let line = String(data: remaining[..<lineEnd.lowerBound], encoding: .ascii) else {
                throw SystemProxySafetyStart.Failure("国内直连返回无效或过大的 HTTP 响应头。")
            }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(parts[0])),
                  parts[1].count == 3, let code = Int(parts[1]), (100...599).contains(code) else {
                throw SystemProxySafetyStart.Failure("国内直连返回无效 HTTP 状态行。")
            }
            if code >= 200 { return code }
            guard code != 101 else { throw SystemProxySafetyStart.Failure("国内直连意外切换 HTTP 协议。") }
            remaining = remaining[end.upperBound...]
        }
        guard remaining.count <= maximumHeadSize else {
            throw SystemProxySafetyStart.Failure("国内直连 HTTP 响应头超过 16 KiB。")
        }
        return nil
    }
}
