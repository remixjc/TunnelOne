# System Extension 签名与分发

TunnelOne v0.2.0 起使用 **macOS System Extension**（`.systemextension`），最低系统 macOS 13。扩展安装在应用内的 `Contents/Library/SystemExtensions/io.github.remixjc.TunnelOne.network-extension.systemextension`，由 `OSSystemExtensionRequest` 激活、替换和移除。

Developer ID 直发包需要签名、公证及匹配的 profiles。开发调试包和未签名预览都不能替代已公证发行包的安装验收。无需关闭 SIP 或 Gatekeeper。

## 标识与权限

| 项目 | 标识 |
| --- | --- |
| 主应用 | `io.github.remixjc.TunnelOne` |
| 系统扩展 | `io.github.remixjc.TunnelOne.network-extension` |
| 登录助手 | `io.github.remixjc.TunnelOne.login-item-helper` |
| macOS App Group | `<TEAM_ID>.group.io.github.remixjc.TunnelOne` |
| 版本化 XPC 服务 | `<App Group>.control.<CFBundleVersion>` |

主应用和系统扩展都声明 Network Extension 权限。**Developer ID** 使用 `packet-tunnel-provider-systemextension`；**Apple Development** 使用 `packet-tunnel-provider`。主应用另外声明 `com.apple.developer.system-extension.install`。这些值由 `NETWORK_EXTENSION_KIND` 构建设置控制。

系统扩展本身不启用 App Sandbox，因为它负责 root 配置存储和以用户身份启动子进程；主应用继续使用 App Sandbox。它们仍使用同一 App Group 命名 XPC 服务，但系统扩展不读取用户共享容器和用户钥匙串。

## 配置如何跨越用户 / 系统边界

1. GUI 将 WireGuard 配置保留在当前用户钥匙串，代理 YAML 保留在用户 App Group 的私有目录。
2. 保存 VPN 设置前，通过 XPC 将完整配置写成一个不可变快照。连接双方都用 `setCodeSigningRequirement` 校验 Apple 签名、Team 和准确的 Bundle ID，服务在每条消息上执行校验。UID 来自 XPC 连接，不能由消息指定。
3. 系统端把快照写在 `/Library/Application Support/io.github.remixjc.TunnelOne/Configurations/<UID>/<UUID>.json`。目录仅 root 可访问（0700），文件仅 root 可读写（0600）。VPN preferences 只保存快照 ID、UID 和不含密钥的代理偏好。
4. 保存 preferences 失败时回收新快照；成功后删除旧快照。删除 VPN 设置成功后删除对应系统快照和用户钥匙串引用。
5. 按需连接从系统快照恢复，不需要主应用在线或用户钥匙串解锁。系统扩展不接受任意文件路径。
6. 启动内置代理时创建私有临时目录，将所有者设为对应用户。root 启动器只负责监督生命周期，**在读取 YAML 或运行 Mihomo 前，通过 fork/exec 降低 UID、GID 和补充组权限**。代理核心使用普通用户权限，环境变量经过清理；正常停止清理临时配置。

服务的快照端点只允许写入、删除和读取固定的错误代码；不提供读取其他用户配置或任意文件的接口。日志与异常不输出私钥、订阅地址或 YAML 内容。macOS 13 是 XPC 每条消息签名校验 API 的最低版本。

## 本地构建

先配置 Apple Developer 的两个明确 App ID，并启用 Network Extensions。macOS 的 Team ID 前缀 App Group 无需在门户单独注册。

复制 `Config/Signing.xcconfig.example` 到 `Config/Signing.xcconfig`：

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = YOUR_DEVELOPER_ID_CERTIFICATE_SHA1
NETWORK_EXTENSION_KIND = packet-tunnel-provider-systemextension
APP_PROFILE = APPLICATION_DEVELOPER_ID_PROFILE_UUID
EXTENSION_PROFILE = EXTENSION_DEVELOPER_ID_PROFILE_UUID
```

用 `security find-identity -v -p codesigning` 查看本机证书指纹；CI 会自动从导入的 p12 选择指纹。构建先关闭 Xcode 自动签名，再由 `scripts/sign_app.py` 嵌入 profiles 并从内到外签名，兼容 Xcode 管理的 Developer ID profiles。

两个 profiles 必须属于同一 Team，匹配各自 Bundle ID，包含 `packet-tunnel-provider-systemextension`，并允许实际使用的 Developer ID Application 证书。

```sh
bash scripts/build.sh --signed
python3 scripts/check_bundle.py build/DerivedData/Build/Products/Release/TunnelOne.app --signed
```

`check_bundle.py` 验证 System Extension 布局、通用架构、主应用与扩展的权限、证书 Team、Developer ID profiles 和有效期。正式打包还需要公证及 staple。

Apple Development 调试可以用 Xcode 自动签名，设置 `NETWORK_EXTENSION_KIND = packet-tunnel-provider`。不要拿开发 profile 代替 Developer ID profile。Xcode 的自动导出可能保留错误的 Network Extension entitlement，正式 CI 使用手动 Developer ID 签名直接构建，并检查最终 entitlements。

## 复用 Magic-Printer 的凭据

两项目使用同一 Apple Team 时，可复用以下五项仓库 secrets，无需为 TunnelOne 重新购买账户或单独创建签名证书：

| Secret | 用途 |
| --- | --- |
| `MAC_CSC_LINK` | 含 Developer ID Application 私钥的 p12，Base64 / data URL / HTTPS URL |
| `MAC_CSC_KEY_PASSWORD` | p12 密码 |
| `APPLE_ID` | Apple 公证账号 |
| `APPLE_APP_SPECIFIC_PASSWORD` | 公证账号的应用专用密码 |
| `APPLE_TEAM_ID` | Apple Team |

额外配置两个 **TunnelOne 专属** secrets：

| Secret | 内容 |
| --- | --- |
| `APPLE_APP_PROFILE` | 主应用 Developer ID `.provisionprofile` 的 Base64 |
| `APPLE_EXTENSION_PROFILE` | 系统扩展 Developer ID `.provisionprofile` 的 Base64 |

GitHub 无法读回已保存的 secrets。可以重新提供原始值，或在源仓库 Actions 内用目标仓库的 public key 将值密封加密，再通过 API 写入目标仓库。不要打印或发布明文凭据。本次迁移使用后者，临时分支与加密中转 artifact 随后删除，源项目主分支不变。

## 自动发布与正式版开关

`build.yml` 支持：

- `main` / PR：无签名编译、测试及预览 artifact。
- 手动运行并选 `require_signed`：缺任一凭据即失败，完整执行 Developer ID 签名、公证和打包；从 tag 运行时发布该版本。
- `v*` tag：凭据齐全则签名；缺失时默认只能发未签名预览。建议仓库变量 `REQUIRE_SIGNED_RELEASE=true`，使 tag 缺凭据直接失败。
- 签名版本默认 `Signed Beta`。仅在真实设备验收完成后将 `RELEASE_CHANNEL=stable`，才能提升正式版。

完整签名流水线：校验证书和 profiles → 导入临时钥匙串 → universal 构建 → 测试与 bundle 检查 → Apple 公证 app → staple app → 打包 ZIP / DMG → 签名与公证 DMG → staple DMG → SHA-256 → 对应源码 → Release。任何公证或签名失败均停止发布；结束后删除临时钥匙串与导入 profiles。

`signed-build.yml` 另保留 Apple Development 调试 artifact，使用 `development-signing` environment 中的开发证书及开发 profiles，不发布正式版。

## 安装、更新和卸载

将 signed 版本拖入 `/Applications` 并打开，允许系统提示的网络扩展和 VPN 权限。较新的 macOS 在「通用 → 登录项与扩展 → 网络扩展」管理授权；较早版本可能在「隐私与安全性」显示允许按钮。系统授权或管理员认证需要设备用户完成。

更新时先断开隧道，再替换应用；启动后自动提交系统扩展替换请求，必要时按系统提示重新启动。XPC 名称包含 build number，避免更新后继续连到旧版本服务。

卸载前先导出并删除本应用所有隧道，再用「TunnelOne → 移除网络扩展…」。系统可能要求管理员授权或重新启动。扩展移除完成后再删除应用。空的 root 配置目录可能保留；不要手动删除 `/Library/SystemExtensions` 内容。

## 验证范围

自动化测试包括配置边界、UID 隔离、不可变快照、路径穿越 / 符号链接拒绝、文件权限和损坏快照，以及代理规则规范化和 universal 布局。它们不等同于实际 VPN 运行验收，详细状态见 [acceptance.md](acceptance.md)。

参考：

- [Apple TN3134](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)
- [Network Extension entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension)
- [Installing System Extensions](https://developer.apple.com/documentation/systemextensions/installing-system-extensions-and-drivers)
- [XPC code signing requirement](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))
