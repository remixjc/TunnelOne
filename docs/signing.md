# 签名与分发路线

本项目当前构建的是 **Packet Tunnel App Extension（`.appex`）**，沿用 WireGuard Apple 的应用结构。

Apple 的 TN3134 明确区分：

| 路线 | Packet Tunnel 包装 | 权限 |
| --- | --- | --- |
| Xcode 开发调试 | App Extension | `packet-tunnel-provider` + 开发 profiles |
| Mac App Store | App Extension | `packet-tunnel-provider` + App Store 分发 |
| Developer ID 直接分发 | System Extension | `packet-tunnel-provider-systemextension` + System Extension 安装授权 |

参考：[Apple TN3134](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)、
[Network Extension entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension)。

**给当前 `.appex` 加 Developer ID 签名和公证，并不会自动使它成为支持直接分发的系统扩展。** 因此公开 release 始终为未签名开发预览，不标记为正式 VPN 安装包。

## 本机签名开发构建

需要具备相应能力的 Apple Developer 账户。证书存在不等同于匹配的 profile 已经准备好。

默认标识：

- 应用：`io.github.remixjc.TunnelOne`
- 扩展：`io.github.remixjc.TunnelOne.network-extension`
- 登录助手：`io.github.remixjc.TunnelOne.login-item-helper`
- 共享组：`<TEAM_ID>.group.io.github.remixjc.TunnelOne`

1. 在 Apple Developer 中为应用和扩展创建匹配的 App ID，启用 Network Extension 及需要的 App Group。
2. 生成开发 provisioning profiles，安装到 Xcode；证书私钥必须在本机钥匙串。
3. 复制 `Config/Signing.xcconfig.example` 为 `Config/Signing.xcconfig`，填写 Team 和签名身份。
4. 使用 Xcode 自动签名，或设置 `CODE_SIGN_STYLE = Manual`，分别填写 `APP_PROFILE` 和 `EXTENSION_PROFILE` 的 UUID / profile 名称。
5. 运行 `bash scripts/build.sh --signed`，或打开生成的 Xcode 工程调试。
6. 查看 `codesign --verify --deep --strict <app>`、签名 entitlements 及 embedded profiles，最后完成实际联网验收。

示例：

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
APP_ID_MACOS = io.github.remixjc.TunnelOne
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = Apple Development
APP_PROFILE = YOUR_APPLICATION_PROFILE_UUID
EXTENSION_PROFILE = YOUR_EXTENSION_PROFILE_UUID
```

如果修改 Bundle ID，应用、扩展、助手、App Group 和两个 profiles 必须同步。不能复用不包含 Network Extension 权限的通用 `*` profile。

构建脚本对子进程应用 sandbox inheritance 签名。Mihomo 和 launcher 由扩展启动并继承扩展沙箱；仍需要在真实签名构建中验证进程执行、共享文件访问、网卡绑定和清理行为。

## GitHub 签名开发构建

`signed-build.yml` 是**手动触发的开发构建**，只上传短期 artifact，不发布或提升正式版。签名 profile 可能限制可运行设备，不能把它当作通用发行版。

在仓库的 `development-signing` environment 配置以下 secrets：

| Secret | 内容 |
| --- | --- |
| `APPLE_CERTIFICATE_P12` | 含私钥的 Apple Development p12，Base64 编码 |
| `APPLE_CERTIFICATE_PASSWORD` | p12 密码 |
| `APPLE_TEAM_ID` | Team ID |
| `APPLE_APP_PROFILE` | 应用的开发 `.provisionprofile`，Base64 |
| `APPLE_EXTENSION_PROFILE` | 扩展的开发 `.provisionprofile`，Base64 |

私钥仅导入临时 runner 的独立钥匙串，构建后删除。工作流不会打印密钥内容。此流程尚未使用本项目专属 profiles 完成端到端运行；配置 secrets 后需实际执行并验收。

## 正式直接分发前的工作

需要完成 System Extension 路线，而不仅是增加 secrets：

- 新建并嵌入 `.systemextension` target，通过 `OSSystemExtensionRequest` 激活。
- 按系统扩展的运行身份重新设计配置传递、密钥访问与用户隔离，不能假定可直接读取当前用户钥匙串 / App Group。
- 审核扩展内启动代理进程与沙箱约束；必要时采用独立受管理服务。
- 使用 Developer ID profiles、`packet-tunnel-provider-systemextension` 和安装 entitlement。
- 完成用户授权、重启 / 替换 / 卸载与多用户验收。
- 使用 Developer ID 签名、公证、staple，再发布正式 DMG。

App Store 路线也需要另外审核内置代理进程、签名和应用审核规则。当前没有承诺 App Store 已通过审核。
