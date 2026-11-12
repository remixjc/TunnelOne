// SPDX-License-Identifier: GPL-3.0-or-later
import Cocoa
import NetworkExtension

final class ProxySettingsViewController: NSViewController {
    private let tunnel: TunnelContainer
    private var settings: ProxySettings
    private var pendingProfile: Data?
    private let onSave: () -> Void
    private let enabled = NSButton(checkboxWithTitle: "连接时带入代理", target: nil, action: nil)
    private let source = NSPopUpButton()
    private let host = NSTextField()
    private let port = NSTextField()
    private let bypass = NSTextField()
    private let profileLabel = NSTextField(wrappingLabelWithString: "")
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)

    init(tunnel: TunnelContainer, onSave: @escaping () -> Void) {
        self.tunnel = tunnel
        settings = (try? tunnel.readProxySettings()) ?? ProxySettings()
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        let title = NSTextField(labelWithString: "隧道与代理，一次连接")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString:
            "为「\(tunnel.name)」单独设置。内置 Mihomo 随隧道启停；本机代理可连接已运行的 Clash Party。")
        detail.textColor = .secondaryLabelColor
        enabled.state = settings.enabled ? .on : .off
        source.addItems(withTitles: ["内置 Mihomo", "本机 / 外部 HTTP 代理"])
        source.selectItem(at: settings.source == .builtIn ? 0 : 1)
        source.target = self
        source.action = #selector(sourceChanged)
        host.stringValue = settings.host
        port.stringValue = String(settings.port)
        bypass.stringValue = settings.bypass.joined(separator: ", ")
        profileLabel.stringValue = settings.profileID == nil ? "尚未导入配置" : "已保存配置 · \(settings.profileID!.prefix(8))"
        profileLabel.preferredMaxLayoutWidth = 290
        let importButton = NSButton(title: "导入 YAML 配置…", target: self, action: #selector(importProfile))
        let profileRow = NSStackView(views: [importButton, profileLabel])
        profileRow.spacing = 12
        let help = NSTextField(wrappingLabelWithString:
            "系统 HTTP/HTTPS 代理仅影响遵循系统代理的应用。内置模式固定监听 127.0.0.1，禁用 TUN、DNS 监听和外部控制端口。更改前请断开隧道并关闭按需连接。")
        help.font = .systemFont(ofSize: 12)
        help.textColor = .secondaryLabelColor
        feedback.textColor = .systemRed
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, saveButton])
        buttons.orientation = .horizontal
        buttons.alignment = .trailing
        let stack = NSStackView(views: [
            title, detail, enabled, field("代理来源", source), profileRow,
            field("代理主机", host), field("代理端口", port),
            field("代理例外（逗号分隔）", bypass), help, feedback, buttons
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -28),
            view.widthAnchor.constraint(equalToConstant: 560),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor),
            feedback.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        sourceChanged()
    }

    private func field(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        control.widthAnchor.constraint(equalToConstant: 500).isActive = true
        return stack
    }

    @objc private func sourceChanged() {
        host.isEnabled = source.indexOfSelectedItem == 1
        if source.indexOfSelectedItem == 0 { host.stringValue = "127.0.0.1" }
    }

    @objc private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["yaml", "yml"]
        panel.allowsMultipleSelection = false
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self = self, result == .OK, let url = panel.url else { return }
            do {
                let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
                guard (attributes.fileSize ?? Int.max) <= 5 * 1024 * 1024 else {
                    throw ProxySettings.ValidationError.profile
                }
                let data = try Data(contentsOf: url)
                guard !data.isEmpty, String(data: data, encoding: .utf8) != nil else {
                    throw ProxySettings.ValidationError.profile
                }
                self.pendingProfile = data
                self.settings.profileID = UUID().uuidString
                self.profileLabel.stringValue = "待保存 · \(url.lastPathComponent)"
                self.feedback.stringValue = "配置将在连接时由内置核心校验。"
            } catch { self.feedback.stringValue = error.localizedDescription }
        }
    }

    @objc private func save() {
        guard tunnel.status == .inactive, !tunnel.isActivateOnDemandEnabled else {
            feedback.stringValue = "请先断开隧道并关闭按需连接，再保存代理设置。"
            return
        }
        do {
            settings.enabled = enabled.state == .on
            settings.source = source.indexOfSelectedItem == 0 ? .builtIn : .external
            settings.host = host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.port = Int(port.stringValue) ?? 0
            settings.bypass = bypass.stringValue.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            try settings.validate()
            if let data = pendingProfile, let id = settings.profileID {
                try ProxyProfileStore.write(data, id: id)
            }
            saveButton.isEnabled = false
            tunnel.saveProxySettings(settings) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.saveButton.isEnabled = true
                    if let error = error {
                        self.feedback.stringValue = error.localizedDescription
                    } else {
                        self.onSave()
                        self.dismiss(self)
                    }
                }
            }
        } catch { feedback.stringValue = error.localizedDescription }
    }

    @objc private func cancel() { dismiss(self) }
}
