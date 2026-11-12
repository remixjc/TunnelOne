// SPDX-License-Identifier: GPL-3.0-or-later
import Cocoa
import SystemExtensions

final class SystemExtensionController: NSObject, OSSystemExtensionRequestDelegate {
    static let shared = SystemExtensionController()
    private var request: OSSystemExtensionRequest?

    func activate() { submit(removing: false) }

    func deactivate() {
        let alert = NSAlert()
        alert.messageText = "移除 TunnelOne 网络扩展？"
        alert.informativeText = "请先断开所有隧道并关闭按需连接。系统可能要求管理员授权或重新启动。"
        alert.addButton(withTitle: "移除扩展")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        submit(removing: true)
    }

    private func submit(removing: Bool) {
        guard request == nil, let app = Bundle.main.bundleIdentifier else { return }
        guard Bundle.main.bundleURL.deletingLastPathComponent().path == "/Applications" else {
            show("请先安装 TunnelOne", "将 TunnelOne 拖入「应用程序」，再打开并安装网络扩展。")
            return
        }
        let request = removing
            ? OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: app + ".network-extension", queue: .main)
            : OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: app + ".network-extension", queue: .main)
        request.delegate = self
        self.request = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        show("请允许 TunnelOne 网络扩展",
             "在「系统设置 → 通用 → 登录项与扩展 → 网络扩展」中允许 TunnelOne，然后返回应用。较早的 macOS 在「隐私与安全性」中显示允许按钮。")
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        self.request = nil
        if result == .willCompleteAfterReboot {
            show("重新启动后完成", "系统将在重新启动后完成网络扩展的安装或移除。")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        self.request = nil
        show("网络扩展尚未就绪", error.localizedDescription + "\n可通过 TunnelOne 菜单中的「安装 / 更新网络扩展」重试。")
    }

    private func show(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
