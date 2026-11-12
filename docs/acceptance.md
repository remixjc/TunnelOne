# 验收记录

## v0.2.1 · 原型与 command 流程修订 · 2026-11-12

主窗口与真实安全启动流程的变更见 [实现对照](design/command-parity.md)。已增加代理设置前置检查、临时隧道服务代理同步、两项并行实际 HTTP 检查和失败回滚。自动化检查不更改主机的真实网络；本次尚未进行新扩展的真实联网 / 回滚验收。

自动化测试已通过：22 项 Swift 测试、Go 测试、客户端原生动作桥接与状态展示、官网交互和布局检查。签名、公证与发布结果以 v0.2.1 标签流水线及 Release 为准。

下方 v0.2.0 记录保留为已发布版本的历史验收，不代表 v0.2.1 已通过同样的联网验收。

## v0.2.0 · 2026-11-12

本轮已完成 System Extension 改造、开发归档、专属 Developer ID profiles 生成，以及 Magic-Printer 共用签名 / 公证凭据的加密迁移。当前发行通道为 **Beta**。

### 自动验证

- Swift：6 项代理偏好测试；4 项系统配置测试（UID 分区、不可变快照、权限、损坏数据、符号链接、路径穿越、配置大小）。
- Go：保留节点与规则，覆盖 TUN、DNS 监听、LAN、控制端口和物理网卡绑定；验证规范化配置可由内置 Mihomo 接受。
- Xcode：应用、System Extension、登录助手，`arm64` + `x86_64`；macOS 13 最低版本。
- 分发布局：`.systemextension` 文件名与 Bundle ID 一致，位于 `Contents/Library/SystemExtensions`，不再嵌入 `.appex`。
- 签名检查：Developer ID Application、正确 Team、匹配证书的 profiles、最终 Network Extension entitlement、hardened runtime、无 get-task-allow。
- 网站：资源链接、连接 / 断开演示、代理切换、手机布局及 JavaScript 错误。

CI 会在签名检查后对 app 和 DMG 分别请求 Apple 公证、staple 并验证，再上传 ZIP / DMG / SHA-256 / 对应源码。**每次实际构建结果以该 commit 的 Actions 和 Release 为准。** 自动测试中的 UID 隔离属于文件存储单元测试，不代表真实多用户登录测试已通过。

### 发布与本机验收：部分通过

2026-11-12 的 v0.2.0 tag 流水线 [43144183905](https://github.com/remixjc/TunnelOne/actions/runs/43144183905) 已成功。Apple 分别接受 app 和 DMG 公证，staple / validate 均通过，已发布 Signed Beta。下载发布 ZIP 后，其 SHA-256 与 `SHA256SUMS.txt` 一致；本机 bundle 签名检查和公证票据校验通过，`spctl` 返回 accepted / Notarized Developer ID。本机同时显示 `override=security disabled`，因此该机器的 Gatekeeper 评估不能代表默认安全设置下的新设备验收；本轮未修改系统安全设置。

设备用户随后导入并连接了隧道，并启用外部 Clash Party 代理。观察到实际握手与双向数据，系统只保留 TunnelOne 的 VPN 连接；原 WireGuard VPN 已断开。查询 1.1.1.1 的路由指向 `utun4`，当前 HTTP / HTTPS 代理为 `127.0.0.1:7890`。本机直连百度 HTTPS、经代理访问 Google 和 GitHub 均返回 HTTP 200。该结果证明本轮 WireGuard 与外部代理共存可用；尚未独立核对每条 Clash 节点连接的实际出口路径。

- [x] 发布成品安装到 `/Applications`，系统扩展为 activated enabled，客户端成功启动。
- [x] 实际隧道导入、配置跨 XPC 保存、VPN 授权和连接；近期握手、发送 / 接收流量可见。
- [x] 外部 Clash Party：HTTP / HTTPS 系统代理生效，国内直连和国外代理访问成功。

### 仍需继续验收

- [ ] 在保持默认 Gatekeeper 安全设置的新设备上安装已公证成品。
- [ ] 导入 / 编辑 / 复制 / 删除 / 导出；保存失败后原配置仍可使用。
- [ ] 代理关闭：WireGuard 实际握手、路由、DNS、IPv4 / IPv6。
- [ ] 外部 Clash Party 不可达时的真实回滚；核对各节点连接的实际出口路径。
- [ ] 内置代理：启动器和 Mihomo 确认为普通用户 UID / GID；绑定实际 utun，验证出口路径。
- [ ] 应用关闭或用户钥匙串锁定后按需连接仍能读取系统快照。
- [ ] 错误 YAML、规则下载失败、端口占用、快速启停和启动取消。
- [ ] 代理 / 扩展崩溃、睡眠唤醒、Wi-Fi / 以太网切换，无残留核心。
- [ ] 断开后系统撤销隧道代理，保留原有网络设置。
- [ ] 真实多用户：其他用户不能经 XPC 读取或修改本用户快照；切换用户后行为正确。
- [ ] 升级扩展、更换 XPC 服务版本、移除扩展、重启完成卸载。
- [ ] 大型配置、远程 provider、DNS 引导、IPv6-only 网络。

测试前先导出已有隧道，并停止其他 WireGuard 连接。设备解锁、管理员 / 系统扩展批准以及可能的生物认证由设备用户完成。

v0.2.0 当时检查代理监听 TCP 端口，不强制以 WireGuard 握手或某个网站的状态决定“已连接”；v0.2.1 外部 Clash Party 模式新增实际路由、代理和国内外 HTTP 检查。尚未实现网络 kill switch；断开后系统可能使用原有物理网络。签名、公证和回滚不构成防泄漏保证。

完成以上实际验收后，再把 `RELEASE_CHANNEL` 从 `beta` 改为 `stable`。
