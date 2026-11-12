// SPDX-License-Identifier: GPL-3.0-or-later
import Cocoa
import WebKit

/// Uses the approved prototype's layout and CSS. All actions cross this narrow
/// bridge to the existing native tunnel manager; the page has no network access.
final class TunnelOneViewController: NSViewController, TunnelEditViewControllerDelegate {
    private let manager: TunnelsManager
    private var webView: WKWebView!
    private var timer: Timer?
    private var selectedName: String?
    private var observations: [AnyObject] = []
    private var reports: [String: SafetyStartReport] = [:]
    private var ignoredReportTimes: [String: String] = [:]
    private var runtimes: [String: TunnelConfiguration] = [:]
    private var reportPending = false
    private var runtimePending = false
    private var saving = false
    private var message = ""
    private var logs: [[String: String]] = []
    private var editor: TunnelEditViewController?

    init(tunnelsManager: TunnelsManager) {
        manager = tunnelsManager
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let content = TunnelOneWebView()
        content.onMessage = { [weak self] in self?.receive($0) }
        content.onReady = { [weak self] in self?.publish() }
        webView = content.webView
        view = content
        reloadTunnels()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadTunnels()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshRuntime() }
    }
    override func viewWillDisappear() {
        super.viewWillDisappear()
        timer?.invalidate()
        timer = nil
    }
    deinit { timer?.invalidate() }

    func reloadTunnels() {
        guard isViewLoaded else { return }
        observations.removeAll()
        for tunnel in manager.mapTunnels(transform: { $0 }) {
            observations.append(tunnel.observe(\.status) { [weak self] tunnel, _ in
                DispatchQueue.main.async {
                    if [.activating, .restarting, .waiting].contains(tunnel.status) {
                        self?.beginReport(for: tunnel)
                    }
                    self?.addLog("\(tunnel.name)：\(self?.statusLabel(tunnel.status) ?? "")")
                    self?.publish()
                    self?.refreshRuntime()
                }
            })
        }
        if selectedName == nil || manager.tunnel(named: selectedName!) == nil {
            selectedName = manager.tunnelInOperation()?.name ?? manager.mapTunnels { $0.name }.first
        }
        publish()
        refreshRuntime()
    }

    private var selected: TunnelContainer? { selectedName.flatMap { manager.tunnel(named: $0) } }

    private func statusLabel(_ status: TunnelStatus) -> String {
        switch status {
        case .inactive: return "未连接"
        case .active: return "已连接"
        case .activating: return "正在连接"
        case .deactivating: return "正在断开"
        case .waiting: return "正在等待"
        case .restarting: return "正在重新连接"
        case .reasserting: return "正在恢复连接"
        }
    }

    private func publish() {
        guard isViewLoaded else { return }
        let tunnels: [[String: Any]] = manager.mapTunnels { tunnel in
            let model = TunnelViewModel(tunnelConfiguration: runtimes[tunnel.name] ?? tunnel.tunnelConfiguration)
            let settings = try? tunnel.readProxySettings()
            let demand = ActivateOnDemandViewModel(tunnel: tunnel)
            let peers: [[String: String]] = model.peersData.map { peer in [
                "publicKey": peer[.publicKey], "endpoint": peer[.endpoint],
                "allowedIPs": peer[.allowedIPs], "keepalive": peer[.persistentKeepAlive]
            ] }
            var data: [String: Any] = [
                "id": tunnel.name, "name": tunnel.name,
                "status": tunnel.status.debugDescription, "statusLabel": statusLabel(tunnel.status),
                "proxyEnabled": settings?.enabled ?? false,
                "safetyMode": settings?.source == .external,
                "proxySource": settings?.source == .builtIn ? "已有内置 Mihomo 配置" : "本机代理 · Clash Party",
                "address": model.interfaceData[.addresses], "dns": model.interfaceData[.dns],
                "publicKey": model.interfaceData[.publicKey], "mtu": model.interfaceData[.mtu],
                "listenPort": model.interfaceData[.listenPort],
                "endpoint": peers.first?["endpoint"] ?? "", "allowedIPs": peers.first?["allowedIPs"] ?? "",
                "peers": peers,
                "onDemandEnabled": tunnel.isActivateOnDemandEnabled,
                "onDemandDescription": demand.localizedInterfaceDescription,
                "rx": model.peersData.first?[.rxBytes] ?? "", "tx": model.peersData.first?[.txBytes] ?? "",
                "handshake": model.peersData.first?[.lastHandshakeTime] ?? ""
            ]
            if let report = reports[tunnel.name], let encoded = try? JSONEncoder().encode(report),
               let value = try? JSONSerialization.jsonObject(with: encoded) { data["report"] = value }
            return data
        }
        let data: [String: Any] = [
            "tunnels": tunnels, "logs": logs, "message": message, "saving": saving,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        ]
        webView.callAsyncJavaScript("window.TunnelOne?.update(data)", arguments: ["data": data], in: nil, in: .page, completionHandler: nil)
    }

    private func refreshRuntime() {
        guard let tunnel = selected else { return }
        let name = tunnel.name
        if tunnel.status == .active && !runtimePending {
            runtimePending = true
            tunnel.getRuntimeTunnelConfiguration { [weak self] config in
                DispatchQueue.main.async {
                    self?.runtimePending = false
                    self?.runtimes[name] = config
                    self?.publish()
                }
            }
        } else if tunnel.status == .inactive { runtimes[name] = nil }
        if !reportPending {
            reportPending = true
            tunnel.getSafetyReport { [weak self] report in
                guard let self = self else { return }
                self.reportPending = false
                if let report = report, self.ignoredReportTimes[name] != report.time {
                    if self.reports[name]?.stage != report.stage || self.reports[name]?.result != report.result {
                        self.addLog("\(name)：\(report.stage)\(report.reason.map { " · " + $0 } ?? "")")
                        for check in report.checks { self.addLog("\(check.name)：\(check.ok ? "通过" : "失败") · HTTP \(check.http)") }
                    }
                    self.reports[name] = report
                }
                self.publish()
            }
        }
    }

    private func addLog(_ text: String) {
        let format = DateFormatter()
        format.dateFormat = "HH:mm:ss"
        logs.insert(["time": format.string(from: Date()), "message": text], at: 0)
        logs = Array(logs.prefix(80))
    }

    private func beginReport(for tunnel: TunnelContainer) {
        if let old = reports[tunnel.name] { ignoredReportTimes[tunnel.name] = old.time }
        reports[tunnel.name] = nil
    }

    fileprivate func receive(_ event: WKScriptMessage) {
        guard event.frameInfo.isMainFrame,
              webView.url?.lastPathComponent == "index.html",
              let body = event.body as? [String: Any], let action = body["action"] as? String else { return }
        if let name = body["id"] as? String, manager.tunnel(named: name) != nil { selectedName = name }
        guard action == "ready" || view.window?.attachedSheet == nil else { return }
        message = ""
        switch action {
        case "ready": publish()
        case "select": refreshRuntime()
        case "connect": handleToggleActiveStatusAction()
        case "proxy-toggle":
            guard let enabled = body["value"] as? Bool else { return }
            saveProxy(enabled)
        case "import": handleImportTunnelAction()
        case "export": handleExportTunnelsAction()
        case "new": handleAddEmptyTunnelAction()
        case "edit": handleEditTunnelAction()
        case "tunnel-menu": showTunnelMenu()
        case "open-clash": openClash()
        case "system-logs": handleViewLogAction()
        case "install-extension": (NSApp.delegate as? AppDelegate)?.installNetworkExtension()
        case "remove-extension": (NSApp.delegate as? AppDelegate)?.removeNetworkExtension()
        case "about": (NSApp.delegate as? AppDelegate)?.aboutClicked()
        default: break
        }
        publish()
    }

    private func saveProxy(_ enabled: Bool) {
        guard let tunnel = selected, tunnel.status == .inactive, !tunnel.isActivateOnDemandEnabled, !saving else {
            message = "请先断开隧道并关闭按需连接，再更改代理开关。"; return
        }
        do {
            var settings = try tunnel.readProxySettings()
            settings.enabled = enabled
            settings.source = .external
            settings.host = "127.0.0.1"
            settings.port = 7890
            saving = true
            tunnel.saveProxySettings(settings) { [weak self] error in
                DispatchQueue.main.async {
                    self?.saving = false
                    self?.message = error?.localizedDescription ?? ""
                    if error == nil { self?.beginReport(for: tunnel) }
                    self?.addLog("\(tunnel.name)：\(error == nil ? (enabled ? "下次连接执行 Clash 安全启动" : "下次仅连接 WireGuard") : "代理偏好保存失败")")
                    self?.publish()
                }
            }
        } catch { message = error.localizedDescription }
    }

    private func openClash() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "party.mihomo.app") else {
            message = "未找到 Clash Party，请先安装并配置已有客户端。"; return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    @objc func handleToggleActiveStatusAction() {
        guard let tunnel = selected, !saving else { return }
        if tunnel.status == .inactive {
            beginReport(for: tunnel)
            manager.startActivation(of: tunnel)
        } else if tunnel.isActivateOnDemandEnabled {
            manager.setOnDemandEnabled(false, on: tunnel) { [weak self] error in
                if let error = error { self?.message = error.localizedDescription }
                else { self?.manager.startDeactivation(of: tunnel) }
                self?.publish()
            }
        } else { manager.startDeactivation(of: tunnel) }
    }

    @objc func handleImportTunnelAction() { ImportPanelPresenter.presentImportPanel(tunnelsManager: manager, sourceVC: self) }
    @objc func handleAddEmptyTunnelAction() { showEditor(nil) }
    @objc func handleEditTunnelAction() {
        guard let tunnel = selected else { return }
        PrivateDataConfirmation.confirmAccess(to: tr("macViewPrivateData")) { [weak self] in self?.showEditor(tunnel) }
    }
    private func showEditor(_ tunnel: TunnelContainer?) {
        let controller = TunnelEditViewController(tunnelsManager: manager, tunnel: tunnel)
        controller.delegate = self
        editor = controller
        presentAsSheet(controller)
    }
    func tunnelSaved(tunnel: TunnelContainer) { selectedName = tunnel.name; editor = nil; reloadTunnels() }
    func tunnelEditingCancelled() { editor = nil }

    @objc func handleExportTunnelsAction() {
        PrivateDataConfirmation.confirmAccess(to: tr("macExportPrivateData")) { [weak self] in
            guard let self = self, let window = self.view.window else { return }
            let panel = NSSavePanel()
            panel.allowedFileTypes = ["zip"]
            panel.nameFieldStringValue = "wireguard-export.zip"
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let destination = panel.url else { return }
                ZipExporter.exportConfigFiles(tunnelConfigurations: self.manager.mapTunnels { $0.tunnelConfiguration }.compactMap { $0 },
                                              to: destination) { error in
                    if let error = error { ErrorPresenter.showErrorAlert(error: error, from: self) }
                }
            }
        }
    }
    @objc func handleViewLogAction() { presentAsSheet(LogViewController()) }
    @objc func handleRemoveTunnelAction() {
        guard let tunnel = selected, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "删除「\(tunnel.name)」？"
        alert.informativeText = "删除后将断开该隧道并移除其保存的配置。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .alertFirstButtonReturn else { return }
            self.manager.remove(tunnel: tunnel) { error in
                if let error = error { ErrorPresenter.showErrorAlert(error: error, from: self) }
                self.reloadTunnels()
            }
        }
    }
    private func showTunnelMenu() {
        let menu = NSMenu()
        for (title, selector) in [("编辑隧道", #selector(handleEditTunnelAction)), ("导出所有隧道", #selector(handleExportTunnelsAction)), ("删除隧道", #selector(handleRemoveTunnelAction))] {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
            item.target = self
        }
        menu.popUp(positioning: nil, at: view.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil), in: view)
    }

}
