# 验收记录

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

### 真实设备验收：待完成

本轮执行期间 Mac 处于锁屏状态。尚未在已解锁桌面完成系统扩展授权及以下联网验证：

- [ ] signed 应用复制到 `/Applications`，允许系统扩展与 VPN 权限。
- [ ] 导入 / 编辑 / 复制 / 删除 / 导出；保存失败后原配置仍可使用。
- [ ] 代理关闭：WireGuard 实际握手、路由、DNS、IPv4 / IPv6。
- [ ] 外部 Clash Party 代理：端口可达、系统代理生效、国内外访问；不可达时回滚。
- [ ] 内置代理：启动器和 Mihomo 确认为普通用户 UID / GID；绑定实际 utun，验证出口路径。
- [ ] 应用关闭或用户钥匙串锁定后按需连接仍能读取系统快照。
- [ ] 错误 YAML、规则下载失败、端口占用、快速启停和启动取消。
- [ ] 代理 / 扩展崩溃、睡眠唤醒、Wi-Fi / 以太网切换，无残留核心。
- [ ] 断开后系统撤销隧道代理，保留原有网络设置。
- [ ] 真实多用户：其他用户不能经 XPC 读取或修改本用户快照；切换用户后行为正确。
- [ ] 升级扩展、更换 XPC 服务版本、移除扩展、重启完成卸载。
- [ ] 大型配置、远程 provider、DNS 引导、IPv6-only 网络。

测试前先导出已有隧道，并停止其他 WireGuard 连接。设备解锁、管理员 / 系统扩展批准以及可能的生物认证由设备用户完成。

项目目前检查代理监听 TCP 端口，不强制以 WireGuard 握手或某个网站的状态决定“已连接”。尚未实现网络 kill switch；断开后系统可能使用原有物理网络。签名、公证和回滚不构成防泄漏保证。

完成以上实际验收后，再把 `RELEASE_CHANNEL` 从 `beta` 改为 `stable`。
