<p align="center">
  <img src="website/assets/icon.svg" width="88" alt="TunnelOne">
</p>
<h1 align="center">TunnelOne · 隧行</h1>
<p align="center">一次连接，让 WireGuard 与代理各就其位。</p>
<p align="center">
  <a href="https://remixjc.github.io/TunnelOne/">项目官网</a> ·
  <a href="https://remixjc.github.io/TunnelOne/prototype.html">交互原型</a> ·
  <a href="https://github.com/remixjc/TunnelOne/releases">下载 Beta</a> ·
  <a href="docs/signing.md">签名与发布</a>
</p>
<p align="center">
  <a href="https://github.com/remixjc/TunnelOne/actions/workflows/build.yml"><img src="https://github.com/remixjc/TunnelOne/actions/workflows/build.yml/badge.svg" alt="macOS build"></a>
  <a href="https://github.com/remixjc/TunnelOne/actions/workflows/pages.yml"><img src="https://github.com/remixjc/TunnelOne/actions/workflows/pages.yml/badge.svg" alt="Pages"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-153c36" alt="macOS 13 or newer">
  <img src="https://img.shields.io/badge/license-GPL--3.0-b7f7c1" alt="GPL-3.0">
</p>

TunnelOne 是面向 macOS 的 WireGuard 客户端，为每个隧道提供「连接时沿用系统代理」设置。用户在任意代理客户端开启系统代理后，TunnelOne 自动读取当前配置，将其带入 WireGuard。连接时不启动代理客户端，不读取客户端私有配置，也不要求固定端口。

**当前版本：v0.3.0 · Signed Beta（build 10）。** 支持独立的 HTTP / HTTPS / SOCKS 地址和端口、PAC 与绕过规则。没有系统代理时仅连接 WireGuard；已配置但无法访问时明确报错。连接期间监听来源网络服务的代理变化并更新本次隧道。新导入隧道默认启用自动沿用；保留已有隧道的开关设置和历史内置配置。实现与边界见[系统代理继承方案](docs/design/system-proxy-inheritance.md)，实际验收见[验收记录](docs/acceptance.md)。

发布流水线提供 Apple Silicon / Intel 通用应用、Developer ID 签名、Apple 公证、staple、DMG 和 ZIP。请选择 Release 中的 `-signed` 安装包；`-preview` 仅供开发。当前仍按 Beta 发布。

English: A macOS WireGuard client that inherits the user's existing system proxy, independently of proxy client brand or port. Supports HTTP, HTTPS, SOCKS, PAC and bypass rules, with verification and updates scoped to the active tunnel. System Extension deployment uses Developer ID signing and Apple notarization.

## 为什么做 TunnelOne

WireGuard 可以承担底层上网路由，但连接后生效的隧道网络设置不一定包含已有的系统代理。反复切换两个客户端、手动补代理并不适合作为日常流程。

TunnelOne 把代理偏好保存在各自的 VPN 配置中，由 Network Extension 随隧道应用。菜单栏连接、按需连接与主窗口连接使用同一份设置，主窗口关闭后仍由扩展管理连接。

## 功能与实现范围

| 功能 | v0.3.0 实现 |
| --- | --- |
| WireGuard 隧道管理 | 基于官方 macOS 客户端：新建、导入 `.conf` / ZIP、编辑、启停、删除、导出 |
| 多对端与运行信息 | 公钥、地址、DNS、MTU、AllowedIPs、Endpoint、保活、握手与收发统计 |
| macOS 集成 | 原生 AppKit、菜单栏、Wi-Fi / 以太网按需连接、日志、用户钥匙串、系统扩展安装与移除 |
| 进程与配置隔离 | XPC 每条消息校验签名，系统配置按 UID 隔离；Mihomo 以普通用户身份运行 |
| 每隧道代理开关 | 新隧道默认自动沿用；保留已有偏好；与标准 `.conf` 分开保存 |
| 默认代理入口 | 读取当前生效的系统代理，兼容标准系统代理客户端，不启动指定软件 |
| 安全启动 | 连接前验证代理；系统 Connected 后同步临时代理并验证实际系统请求；失败回滚本次连接 |
| 历史内置配置 | 保留旧配置的内置核心运行支持；主窗口不再引导导入 YAML 或选择新节点 |
| 官网与原型 | 响应式静态官网、可交互模拟、独立设计原型、GitHub Pages 自动部署 |
| 构建与发布 | Apple Silicon + Intel universal；ZIP、DMG、SHA-256；tag 触发签名、公证及 Beta 发布 |

当前**没有**实现订阅 URL 管理、节点可视化选择、测速、应用内自动更新和独立的全应用 TUN 代理。节点、规则和订阅继续由用户选择的代理客户端管理。原型内的数据与连接为模拟；应用窗口读取实际隧道状态、统计和扩展检查报告，不使用模拟结果。

## 工作原理

1. 连接前读取当前生效的系统代理，分别保存 HTTP、HTTPS、SOCKS、PAC 和绕过规则。通过系统网络栈验证快照对应的访问规则。
2. 启动用户选择的 WireGuard 隧道，优先通过 NEProxySettings 设置 HTTP / HTTPS / PAC。等待系统 Connected 与一秒稳定期后，定位属于本次接口的临时网络服务，将完整代理字典（含 SOCKS）同步到其 State。
3. 核对实际生效的代理与快照一致，再通过默认系统代理规则请求 Google。全 IPv4 隧道同时执行绑定本次接口并绕过代理的百度 HTTPS 检查；仅内网隧道不强制接管公网路由。
4. 监听物理网络服务的代理变化，更新本次隧道并重新验证；不把自身写入的 VPN 配置作为新来源。失败时断开本次 WireGuard，保留用户的来源代理。
5. 断开时由系统撤销该隧道的临时网络设置，不向物理网络或永久 Setup 写回旧快照。

系统代理仅影响遵循它的应用，不保证 UDP 或忽略系统代理的程序经过代理。代理客户端的节点出站仍受其自身接口绑定和 WireGuard AllowedIPs 影响，不保证所有节点连接都强制从 WireGuard 出口发出。仅 TUN / 其他 VPN、WPAD 和额外认证代理属于单独的兼容范围。

历史内置 Mihomo 模式继续保留，使用其独立的 YAML、端口和接口绑定设置；自动沿用系统代理不使用这些字段。

## 使用方法

以下连接步骤针对已完成正确签名的构建。使用预览前请先阅读[签名指南](docs/signing.md)。

1. 把 signed 应用放到 `/Applications`，打开 TunnelOne，按系统提示允许网络扩展。
2. 导入 WireGuard `.conf` 或 ZIP；首次连接允许系统添加 VPN 配置。
3. 在自己的代理客户端中启用系统代理并确认可以访问网络，使用其已有端口、节点与规则。
4. 选中隧道，保留「连接时沿用系统代理」，然后点击「开启」。没有系统代理时会明确显示本次仅连接 WireGuard。
5. 若代理已配置但不可用，应用显示实际失败原因；不要将连接失败当成代理已生效。

修改代理开关前需断开隧道并关闭按需连接；新导入隧道默认自动沿用，旧隧道保留原开关状态。标准 WireGuard 导出不包含代理偏好。历史内置模式可继续使用，关闭再开启主窗口开关会改为自动沿用。按需连接同样执行扩展内检查，依赖已有代理服务可用。

`examples/proxy.yaml` 是不含节点凭据的 DIRECT 示例，只用于理解格式，不提供网络服务。代理 YAML 首先做 UTF-8 与大小检查，连接时再由 YAML 解析器和 Mihomo 校验。

## 开发与构建

需要 macOS 13+、完整 Xcode 15+、Python 3.12+ 和 XcodeGen。已在 Xcode 27.0 上进行本地构建验证；CI 使用 GitHub macOS runner。

```bash
git clone git@github.com:remixjc/TunnelOne.git
cd TunnelOne
brew install xcodegen python@3.12
bash scripts/build.sh
```

构建脚本会：

- 从官方地址获取固定版本依赖并校验 SHA-256。
- 使用隔离的 `.tools/go` 构建 WireGuard Go bridge 与核心启动器；不修改全局 Go 安装。
- 生成 `TunnelOne.xcodeproj`，构建 `arm64` + `x86_64` 应用和扩展，嵌入 universal Mihomo。

产物：`build/DerivedData/Build/Products/Release/TunnelOne.app`。

WireGuard 上游固定的 Go runtime 补丁需要 **Go 1.19.13**；这是构建兼容性约束，不能直接切到新 Go。`scripts/dependencies.lock.json` 与 Go `go.sum` 固定输入。正式版前应完成 WireGuard 后端与工具链升级审计。

下载 Go 模块受限时，可在本次命令中设置自己的 `GOPROXY`，例如：

```bash
GOPROXY=https://goproxy.cn,direct bash scripts/build.sh
```

### 测试与打包

```bash
bash scripts/test.sh
node scripts/client-ui.test.cjs
bash scripts/test_native_ui.sh
bash scripts/package.sh preview

# 网站测试（需 Node.js）
npm ci
npx playwright install chromium
npm run test:site

# 本地预览官网
python3 -m http.server 8080 --directory website
```

测试覆盖代理偏好校验、数据损坏时拒绝启动、配置往返、YAML 中危险路由与监听设置的覆盖，以及官网连接/开关交互与移动端布局。签名后的真实联网验收另见[测试清单](docs/acceptance.md)。

### 签名构建

```bash
cp Config/Signing.xcconfig.example Config/Signing.xcconfig
# 填写自己的 Team、签名身份，配置匹配的 App ID / profiles
bash scripts/build.sh --signed
```

正式直发使用 Developer ID Application、主应用和系统扩展的专属 Developer ID profiles，以及 `packet-tunnel-provider-systemextension` 权限；App Group 必须一致。不要把证书、私钥或 provisioning profiles 提交到仓库。完整流程见[签名与公证](docs/signing.md)。

## 自动化

| 触发 | 工作流 | 结果 |
| --- | --- | --- |
| PR、push 到 main、手动触发 | `build.yml` | 编译、测试、上传预览 ZIP / DMG 等 artifact |
| push 到 main（网站更新）、手动触发 | `pages.yml` | 测试官网并部署 `website/` 到 GitHub Pages |
| push `v*` tag | `build.yml` | 检查版本、签名、公证、打包、附对应源码后发布 Signed Beta |
| 手动触发（需签名环境） | `signed-build.yml` | 签名开发构建并上传 artifact，不提升正式版 |

发布新版本（签名凭据齐全时自动公证）：

```bash
git tag v0.3.0
git push origin v0.3.0
```

后续版本先更新 `VERSION` 与 `project.yml`，添加 `docs/releases/<版本>.md`，再推送对应 tag。工作流拒绝版本不一致的发布，且不会把未签名预览标成正式版。签名版本默认仍为 Beta；完成真实设备验收后才将仓库变量 `RELEASE_CHANNEL` 改为 `stable`。

## 项目结构

```text
Sources/
  WireGuardApp/               原生 macOS 应用、代理设置与扩展安装
  SystemExtension/           系统扩展入口、认证 XPC、root 配置隔离
  WireGuardNetworkExtension/  WireGuard + 代理生命周期
  WireGuardKit*/              上游 WireGuard 底层组件
  Shared/                    钥匙串、日志、配置与代理文件存储
  TunnelOneShared/           可独立测试的代理偏好模型
CoreLauncher/                YAML 规范化、核心进程与父进程监控
Tests/                       Swift 偏好模型测试
website/                     官网与设计原型
docs/                        签名、架构、验收及发布说明
scripts/                     依赖锁定、构建、测试与打包
.github/workflows/           CI、Pages 和发布
```

保留的 iOS 上游源码不属于当前构建目标；本项目目前仅支持 macOS。

## 数据与隐私

WireGuard 私钥继续使用系统钥匙串和上游访问控制。代理 YAML 存在本机 App Group 容器 `ProxyProfiles/<UUID>.yaml`，目录权限 `0700`、文件权限 `0600`；它包含敏感节点信息，当前不额外加密。配置不会上传到项目服务器，应用没有遥测。YAML 中的远程 provider 仍可能按其自身配置访问订阅与规则服务。

运行时派生配置位于对应 profile 的私有缓存目录，正常停止时删除。异常退出可能留下文件。重新导入会创建新 profile；旧 profile 暂不自动清理。清理前请断开隧道并确认配置不再使用。

请勿在 issue 中贴出私钥、预共享密钥、真实订阅 URL 或完整代理 YAML。导出标准 WireGuard 配置会包含私钥。

## 许可证与致谢

新增代码及 TunnelOne 修改采用 **GPL-3.0-or-later**。WireGuard 官方代码保留 MIT 许可证及原始版权声明；独立 Mihomo 二进制采用 GPL-3.0。发布附带相应源码与第三方声明。详情见 [ThirdParty/NOTICE.md](ThirdParty/NOTICE.md) 和[源码获取说明](docs/third-party.md)。

本项目与 WireGuard LLC、MetaCubeX 无隶属关系。感谢 WireGuard Apple、wireguard-go、Mihomo 与 YAML v3 的贡献者。
