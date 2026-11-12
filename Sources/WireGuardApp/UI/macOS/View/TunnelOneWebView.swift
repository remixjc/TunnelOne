// SPDX-License-Identifier: GPL-3.0-or-later
import Cocoa
import WebKit

/// Shared by the application and the sandboxed native UI smoke test.
/// Navigation remains confined to the bundled page even though WebKit needs
/// the network-client sandbox entitlement to launch its helper processes.
final class TunnelOneWebView: NSView, WKNavigationDelegate {
    let webView: WKWebView
    var onMessage: ((WKScriptMessage) -> Void)?
    var onReady: (() -> Void)?
    private(set) var loadError: String?
    private let directory: URL?
    private var watchdog: DispatchWorkItem?
    private let errorPanel = NSView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    init(directory: URL? = Bundle.main.resourceURL?.appendingPathComponent("TunnelOneUI")) {
        self.directory = directory
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: NSRect(x: 0, y: 0, width: 1024, height: 760))
        configuration.userContentController.add(TunnelOnePageMessageHandler(owner: self), name: "tunnelOne")
        webView.navigationDelegate = self
        for child in [webView, errorPanel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: leadingAnchor),
                child.trailingAnchor.constraint(equalTo: trailingAnchor),
                child.topAnchor.constraint(equalTo: topAnchor),
                child.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        errorPanel.wantsLayer = true
        errorPanel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let title = NSTextField(labelWithString: "界面加载失败")
        title.font = .boldSystemFont(ofSize: 20)
        let retry = NSButton(title: "重新加载", target: self, action: #selector(reloadPage))
        let stack = NSStackView(views: [title, errorLabel, retry])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        errorPanel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: errorPanel.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: errorPanel.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: errorPanel.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: errorPanel.trailingAnchor, constant: -24)
        ])
        reloadPage()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { watchdog?.cancel() }

    @objc func reloadPage() {
        watchdog?.cancel()
        loadError = nil
        errorPanel.isHidden = true
        webView.isHidden = false
        guard let directory = directory,
              ["index.html", "app.css", "app.js", "lucide.min.js"].allSatisfy({
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
              }) else {
            showFailure("应用界面文件缺失，请重新下载并安装 TunnelOne。")
            return
        }
        let timeout = DispatchWorkItem { [weak self] in
            self?.showFailure("界面加载超时。请重新加载；如果仍然失败，请退出并重新打开应用。")
        }
        watchdog = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
        webView.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
    }

    private func showFailure(_ detail: String) {
        watchdog?.cancel()
        loadError = detail
        errorLabel.stringValue = detail
        webView.isHidden = true
        errorPanel.isHidden = false
        NSLog("TunnelOne UI: %@", detail)
    }

    private func allows(_ url: URL?) -> Bool {
        guard let url = url, url.isFileURL, let directory = directory else { return false }
        return url.standardizedFileURL == directory.appendingPathComponent("index.html").standardizedFileURL
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, allows(message.frameInfo.request.url) else { return }
        onMessage?(message)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("typeof window.TunnelOne?.update === 'function'") { [weak self] value, error in
            guard let self = self else { return }
            guard error == nil, value as? Bool == true else {
                self.showFailure("界面脚本未能启动，请重新加载或重新安装应用。")
                return
            }
            self.watchdog?.cancel()
            self.onReady?()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showFailure("无法加载应用界面：\(error.localizedDescription)")
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showFailure("应用界面加载失败：\(error.localizedDescription)")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        showFailure("界面进程意外退出，请重新加载；如果反复出现，请安装最新修正版。")
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(allows(navigationAction.request.url) ? .allow : .cancel)
    }
}

private final class TunnelOnePageMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: TunnelOneWebView?
    init(owner: TunnelOneWebView) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}
