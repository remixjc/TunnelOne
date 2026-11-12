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

TunnelOne 是面向 macOS 的 WireGuard 客户端。在 WireGuard 官方 Apple 客户端的基础上，为每个隧道增加「连接时带入代理」开关。关闭时只连接 WireGuard；开启时使用现有 Clash Party，执行安全启动 command 对应的检查、隧道代理同步、国内外联网验证和失败回滚。

**v0.2.1 更新：** 主窗口采用原型的侧栏、概览 / 隧道配置 / 按需连接标签页和代理开关布局；通过原生桥接操作真实的隧道管理器。默认代理来源改为本机 Clash Party 的 `127.0.0.1:7890`，不要求另行导入代理 YAML。真实联网验收状态及与 command 的对应关系见 [command 流程对照](docs/design/command-parity.md)。v0.2.0 的历史验收记录不能作为本次新安全启动流程的联网验收证明。

**当前版本：v0.2.1 · Signed Beta。** 使用 Developer ID 直接分发的系统扩展架构，提供签名、Apple 公证、staple、DMG 和 ZIP 自动发布流程。签名包使用 `-signed` 文件名；未签名包使用 `-preview` 文件名。实际公证和构建结果以对应 Release / Actions 为准。v0.2.0 曾在本机验证安装、系统扩展激活、WireGuard 实际握手及 Clash Party 代理访问；v0.2.1 新流程的真实联网与回滚，以及内置代理、多用户、更新和卸载等验收仍需继续，当前按 Beta 发布。

English: A native macOS WireGuard client with per-tunnel proxy preferences and a bundled Mihomo process. Uses a macOS System Extension with authenticated XPC configuration handoff and a per-user proxy process. Signed distributions require Developer ID profiles and successful Apple notarization; unsigned previews remain available for development. The current release is a beta pending device acceptance.

## 为什么做 TunnelOne

WireGuard 可以承担底层上网路由，但连接后生效的隧道网络设置不一定包含已有的系统代理。反复切换两个客户端、手动补代理并不适合作为日常流程。

TunnelOne 把代理偏好保存在各自的 VPN 配置中，由 Network Extension 随隧道应用。菜单栏连接、按需连接与主窗口连接使用同一份设置，主窗口关闭后仍由扩展管理连接。

## 功能与实现范围

| 功能 | v0.2.1 实现 |
| --- | --- |
| WireGuard 隧道管理 | 基于官方 macOS 客户端：新建、导入 `.conf` / ZIP、编辑、启停、删除、导出 |
| 多对端与运行信息 | 公钥、地址、DNS、MTU、AllowedIPs、Endpoint、保活、握手与收发统计 |
| macOS 集成 | 原生 AppKit、菜单栏、Wi-Fi / 以太网按需连接、日志、用户钥匙串、系统扩展安装与移除 |
| 进程与配置隔离 | XPC 每条消息校验签名，系统配置按 UID 隔离；Mihomo 以普通用户身份运行 |
| 每隧道代理开关 | 默认关闭；与标准 `.conf` 分开保存，编辑隧道时保留代理偏好 |
| 默认代理入口 | 使用现有 Clash Party；主窗口和菜单栏连接时尝试在后台打开客户端 |
| 安全启动 | 检查 Clash 系统代理 / TUN / 模式 / 端口；确认路由及生效的 HTTP/HTTPS/SOCKS 代理；运行两项联网检查，失败回滚 |
| 历史内置配置 | 保留旧配置的内置核心运行支持；主窗口不再引导导入 YAML 或选择新节点 |
| 官网与原型 | 响应式静态官网、可交互模拟、独立设计原型、GitHub Pages 自动部署 |
| 构建与发布 | Apple Silicon + Intel universal；ZIP、DMG、SHA-256；tag 触发签名、公证及 Beta 发布 |

当前**没有**实现订阅 URL 管理、节点可视化选择、测速、应用内自动更新和独立的全应用 TUN 代理。节点、规则和订阅继续由已有 Clash Party 管理。原型内的数据与连接为模拟；应用窗口读取实际隧道状态、统计和扩展检查报告，不使用模拟结果。

## 工作原理

```text
遵循系统代理的应用
        │
        ▼
本机 HTTP/HTTPS mixed 端口
        │
        ▼
Mihomo 规则：DIRECT 或代理节点
        │
        ▼
WireGuard 实际 utun 接口 → WireGuard 服务器 → 目标 / 代理节点
```

1. 主应用从用户钥匙串读取 WireGuard 配置，经签名校验的 XPC 写入按 UID 隔离的系统快照；系统扩展从快照启动 WireGuardAdapter。
2. 通过 `NEProxySettings` 为该隧道设置 HTTP/HTTPS 代理。网络变化后重新应用设置时仍保留代理。
3. 内置模式在 WireGuard 安装路由后启动核心；使用 adapter 返回的实际 `utun` 接口约束核心出站，不依赖固定的 `utun4`。
4. 导入 YAML 会保留节点与规则，但覆盖 TUN、DNS 监听、额外监听端口、控制 API、LAN 访问与网卡绑定，避免配置接管另一套路由。
5. 代理监听通过 TCP 检查后完成启动；失败则停止内置核心与 WireGuard。断开时由系统撤销该隧道的网络设置，停止本次内置进程。

「DIRECT」表示不经远端代理节点。内置模式仍绑定 WireGuard 接口出站。外部代理的节点、TUN、网卡绑定与出站策略由外部应用管理；使用 Clash Party 兼容模式时应关闭其 TUN。

此开关只配置系统 **HTTP/HTTPS** 代理，不保证忽略系统代理的程序或 UDP 流量通过 Mihomo。WireGuard 的路由范围仍由 AllowedIPs 决定。TCP 端口就绪也不等同于已握手或目标网站可达。

## 使用方法

以下连接步骤针对已完成正确签名的构建。使用预览前请先阅读[签名指南](docs/signing.md)。

1. 把 signed 应用放到 `/Applications`，打开 TunnelOne，按系统提示允许网络扩展。
2. 导入 WireGuard `.conf` 或 ZIP；首次连接允许系统添加 VPN 配置。
3. 在 Clash Party 中保持「系统代理开启、TUN 关闭、规则模式、混合端口 7890」。
4. 选中隧道，在概览打开「连接时带入代理」，然后点击「开启」。
5. 应用检查物理网络代理，建立 WireGuard、同步隧道代理，并检查百度直连与 Google 代理访问。全部通过才保持连接，失败则停止本次隧道，保留原有 Clash。只需要 WireGuard 时关闭该开关。

修改代理开关前必须断开该隧道并暂时关闭按需连接。保存后下次连接生效。导入的 WireGuard 隧道默认关闭代理；标准 WireGuard 导出文件不包含代理偏好。已有内置模式设置会保留，关闭再打开主窗口的代理开关会改用 Clash Party。按需连接同样执行扩展内的安全检查，但需要 Clash Party 已在对应用户会话中运行。

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
git tag v0.2.1
git push origin v0.2.1
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
