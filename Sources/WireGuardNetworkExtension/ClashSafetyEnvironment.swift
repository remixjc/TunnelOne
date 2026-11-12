// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SystemConfiguration

final class MacClashSafetyEnvironment: ClashSafetyEnvironment {
    private let home: URL
    private let store = SCDynamicStoreCreate(nil, "TunnelOne.SafeStart" as CFString, nil, nil)!
    private let performActiveMutation: (() throws -> Void) throws -> Void

    init(home: URL, performActiveMutation: @escaping (() throws -> Void) throws -> Void) {
        self.home = home
        self.performActiveMutation = performActiveMutation
    }

    func clashConfiguration() throws -> (app: String, core: String) {
        let directory = home.appendingPathComponent("Library/Application Support/mihomo-party")
        func read(_ name: String) throws -> String {
            let file = directory.appendingPathComponent(name)
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 5 * 1024 * 1024 else { throw ClashSafetyStart.Failure("Clash 配置过大，未启动隧道。") }
            return try String(contentsOf: file, encoding: .utf8)
        }
        do { return try (read("config.yaml"), read("mihomo.yaml")) }
        catch { throw ClashSafetyStart.Failure("无法读取 Clash Party 配置，请先打开 Clash Party 并完成配置。") }
    }

    func primaryNetwork() throws -> (service: String, interface: String) {
        guard let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let service = value["PrimaryService"] as? String, UUID(uuidString: service) != nil,
              let interface = value["PrimaryInterface"] as? String else {
            throw ClashSafetyStart.Failure("无法确定当前主网络服务，未修改代理。")
        }
        return (service, interface)
    }

    func effectiveProxy() throws -> [String: Any] {
        SCDynamicStoreCopyProxies(store) as? [String: Any] ?? [:]
    }

    func proxyDictionary(key: String) throws -> [String: Any]? {
        SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
    }

    func setProxyDictionary(_ value: [String: Any], service: String) throws {
        try performActiveMutation {
            guard UUID(uuidString: service) != nil,
                  SCDynamicStoreSetValue(store, "State:/Network/Service/\(service)/Proxies" as CFString, value as CFDictionary) else {
                throw ClashSafetyStart.Failure("同步隧道临时服务的 Clash 代理失败。")
            }
        }
    }

    func ipv4RouteInterface() throws -> String {
        let result = try command("/sbin/route", ["-n", "get", "1.1.1.1"], timeout: 8)
        guard result.status == 0,
              let range = result.output.range(of: "(?m)interface:\\s*(\\S+)", options: .regularExpression) else { return "" }
        return result.output[range].split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
    }

    func tunnelConnected(interface: String) throws -> Bool {
        // The primary service is a temporary NE service, not the saved VPN ID.
        // Match the adapter's interface against the saved connections' status.
        guard let preferences = SCPreferencesCreate(nil, "TunnelOne.SafeStart" as CFString, nil),
              let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else { return false }
        for service in services {
            guard let id = SCNetworkServiceGetServiceID(service),
                  let connection = SCNetworkConnectionCreateWithServiceID(nil, id, nil, nil),
                  SCNetworkConnectionGetStatus(connection) == .connected,
                  let status = SCNetworkConnectionCopyExtendedStatus(connection) as? [String: Any],
                  let ipv4 = status["IPv4"] as? [String: Any],
                  ipv4["InterfaceName"] as? String == interface else { continue }
            return true
        }
        return false
    }

    func probe(proxy: Bool) throws -> SafetyProbe {
        let options = proxy ? ["--noproxy", "", "--proxy", "http://127.0.0.1:7890"] : ["--noproxy", "*"]
        let url = proxy ? "https://www.google.com/generate_204" : "https://www.baidu.com"
        let result = try command("/usr/bin/curl", [
            "--disable", "--silent", "--show-error", "--output", "/dev/null", "--connect-timeout", "4",
            "--max-time", "7", "--write-out", "%{http_code}"
        ] + options + [url], timeout: 9)
        let code = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return SafetyProbe(name: proxy ? "国外代理" : "国内直连",
                           ok: result.status == 0 && (200..<400).contains(Int(code) ?? 0), http: code,
                           exitCode: result.status, detail: result.error.isEmpty ? nil : result.error)
    }

    func pause() { Thread.sleep(forTimeInterval: 0.25) }

    private func command(_ executable: String, _ args: [String], timeout: TimeInterval) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/empty"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let readers = DispatchGroup()
        var errorData = Data()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        readers.wait()
        deadline.cancel()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "",
                String((String(data: errorData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).prefix(2048)))
    }
}
