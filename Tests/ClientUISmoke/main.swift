// SPDX-License-Identifier: GPL-3.0-or-later
import Cocoa
import WebKit

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("Native UI smoke failed: \(message)\n", stderr); exit(1) }
}

final class Smoke {
    let content = TunnelOneWebView()
    var window: NSWindow!
    var receivedReady = false
    var reloaded = false

    func start() {
        window = NSWindow(contentRect: content.bounds, styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.contentView = content
        content.onMessage = { [weak self] message in
            guard let self = self, let body = message.body as? [String: Any] else { return }
            if body["action"] as? String == "ready" { self.receivedReady = true }
            if body["action"] as? String == "connect" {
                require(self.reloaded, "connect must be delivered after renderer recovery")
                require(body["id"] as? String == "fixture", "native action has wrong tunnel")
                self.verifyBlockedNavigation()
            }
        }
        content.onReady = { [weak self] in self?.verifyPage() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            fputs("Native UI smoke timed out: \(self.content.loadError ?? "no page response")\n", stderr)
            exit(1)
        }
    }

    func verifyPage() {
        let tunnel: [String: Any] = [
            "id": "fixture", "name": "Native sandbox test", "status": "inactive", "statusLabel": "未连接",
            "proxyEnabled": true, "safetyMode": true, "proxySource": "本机代理 · Clash Party",
            "peers": [], "onDemandEnabled": false
        ]
        let payload: [String: Any] = [
            "tunnels": [tunnel], "logs": [], "message": "", "saving": false,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        ]
        content.webView.callAsyncJavaScript("""
            window.TunnelOne.update(data);
            return {title: document.querySelector('h1').textContent,
                    width: document.querySelector('.to-sidebar').getBoundingClientRect().width,
                    status: document.querySelector('.to-status-title').textContent,
                    icons: document.querySelectorAll('svg').length};
            """, arguments: ["data": payload], in: nil, in: .page) { result in
            guard case .success(let value) = result, let values = value as? [String: Any] else {
                fputs("Native UI JavaScript failed: \(result)\n", stderr); exit(1)
            }
            require(self.receivedReady, "page did not send ready through the production bridge")
            require(self.content.loadError == nil, "page reported a load error")
            require(values["title"] as? String == "Native sandbox test", "fixture did not render")
            require(values["width"] as? Int == 208, "prototype CSS did not load")
            require(values["status"] as? String == "隧道未连接", "connection status is incorrect")
            require((values["icons"] as? Int ?? 0) > 0, "bundled icon script did not load")
            if self.reloaded {
                self.content.webView.evaluateJavaScript("document.querySelector('[data-action=\"connect\"]').click()")
            } else {
                self.content.webView.takeSnapshot(with: nil) { image, error in
                    guard let data = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                          let png = bitmap.representation(using: .png, properties: [:]) else {
                        fputs("Native snapshot failed: \(String(describing: error))\n", stderr); exit(1)
                    }
                    let path = FileManager.default.temporaryDirectory.appendingPathComponent("native-ui-smoke.png")
                    do { try png.write(to: path) } catch { fputs("\(error)\n", stderr); exit(1) }
                    print("Snapshot: \(path.path)")
                    self.content.webViewWebContentProcessDidTerminate(self.content.webView)
                    require(self.content.loadError != nil && self.content.webView.isHidden,
                            "renderer termination must show a native error, not a blank web view")
                    self.reloaded = true
                    self.receivedReady = false
                    self.content.reloadPage()
                }
            }
        }
    }

    func verifyBlockedNavigation() {
        content.webView.evaluateJavaScript("location.href = 'https://example.invalid/blocked'")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            require(self.content.webView.url?.isFileURL == true, "remote navigation escaped bundle")
            let missing = TunnelOneWebView(directory: Bundle.main.resourceURL?.appendingPathComponent("MissingUI"))
            require(missing.loadError != nil && missing.webView.isHidden, "missing resources must show a native error")
            print("Sandboxed WKWebView: resources, CSS, icons, native bridge, snapshot, crash recovery and missing-resource fallback passed.")
            exit(0)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let smoke = Smoke()
smoke.start()
app.run()
