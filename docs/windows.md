# Windows 客户端

TunnelOne v0.4.0 新增 Windows 原生客户端。支持 **Windows 10 2004（build 19041）及以上 / Windows 11，x64 与 ARM64**。安装包内含 .NET 10 运行时及固定版本的官方 WireGuard MSI，不需要单独安装 .NET。Windows 版当前为 Preview；macOS 的 Signed Beta 状态不代表 Windows 已签名或完成真实 VPN 联网验收。

## 安装与使用

1. 从 [v0.4.0 Release](https://github.com/remixjc/TunnelOne/releases/tag/v0.4.0) 按设备架构下载 `TunnelOne-0.4.0-windows-x64-setup.exe` 或 `TunnelOne-0.4.0-windows-arm64-setup.exe`。也提供对应的 `-portable.zip` 和 `SHA256SUMS-Windows-<架构>.txt`。
2. 安装程序在缺少 WireGuard 时安装随包提供的官方 WireGuard 1.1.1。便携版先安装包内 `Dependencies/wireguard.msi`，再运行 `TunnelOne.exe`。已有官方客户端可以继续使用。系统会要求管理员授权，以管理隧道服务；请使用自己的管理员账户，使用其他账户的凭据提升会读取那个账户的配置与代理。
3. 导入现有 `.conf` 或 ZIP；也可新建、编辑、删除或导出配置。每个隧道单独保存“连接时沿用系统代理”偏好。标准导出只包含 WireGuard 配置，含明文私钥。
4. 在自己的代理客户端中启用 Windows 系统代理，再连接隧道。TunnelOne 不打开代理客户端、不读取其私有配置、不指定代理端口。
5. 连接后分别显示 WireGuard 服务状态、最新握手及收发统计。服务运行与 HTTPS 检查通过不等于 VPN 已握手；内网隧道可以保持“尚无握手”，应按实际内网目标验证。
6. 最小化窗口后从系统托盘恢复。**关闭窗口或退出会断开本次隧道**。异常退出后，下次启动自动清理本账户的 TunnelOne 遗留服务；也可点击“清理遗留连接”。启动时将服务设为手动启动，避免开机自动连接未经检查的隧道。异常退出至下次清理前，服务可能继续运行。

Windows 版不修改用户全局代理、WinHTTP 代理或其他 WireGuard 客户端的隧道。Windows 的用户系统代理本身就能在 WireGuard 连接期间继续使用，因此无需复制 macOS 的临时网络服务写入机制。

## 系统代理检查

- 读取当前用户的 Internet Options / Windows 系统代理，交给 .NET 的 Windows 系统代理解析器处理手动代理、PAC 与绕过规则。新建代理实例以读取最新设置，不使用进程 `HTTP_PROXY` 等环境变量作为替代来源。
- 有系统代理时，连接前后通过系统规则请求 `https://www.google.com/generate_204` 并要求 HTTP 204；无代理时只建立 WireGuard，不要求公共互联网可达。PAC / 绕过规则可以选择直连，因此界面明确说明检查的是系统规则，而非保证经过代理节点。
- 每 4 秒检查代理设置是否变化；变化后重新验证。代理检查失败会移除本次 TunnelOne 服务，清理失败时保留连接所有权并允许重试断开。用户的代理设置保持当前值。
- Windows 默认可能仅勾选自动发现（WPAD），这不代表已有可用代理。未显式配置手动代理或 PAC 时，显示 WPAD 未验证并仅连接 WireGuard，不因公共检查目标不可达而阻止内网隧道。
- 关闭偏好只跳过检查，Windows 已有系统代理仍可能影响遵循它的应用。HTTP、HTTPS 和 PAC 的实际兼容性取决于 Windows / .NET 的系统解析结果；仅 SOCKS、WPAD、认证代理、其他 VPN/TUN 组合尚未完成兼容验收。不会执行 WireGuard 的 PreUp/PostUp/PreDown/PostDown 或其他脚本。
- 不保证 UDP、游戏或忽略系统代理的应用经过代理，也不保证代理节点出站一定经 WireGuard。默认路由 `/0` 可能触发官方 Windows WireGuard 的限制性防火墙；请按实际路由、DNS 和代理客户端配置验收，TunnelOne 不自动弱化该防火墙。

## 存储与恢复

- 用户配置与代理偏好：`%LOCALAPPDATA%\TunnelOne\Profiles\*.profile`，使用当前用户 Windows DPAPI 加密，并限制目录 ACL。不要直接复制到其他账户/电脑；迁移请使用标准导出。
- 服务配置：`%ProgramData%\TunnelOne\<账户哈希>\*.conf.dpapi`，机器 DPAPI 加密，目录仅 SYSTEM 与管理员可访问。描述字段与服务名一致，兼容官方 WireGuard 的解密校验。正常断开删除；异常退出由下一次启动回收。
- 服务名包含账户哈希与随机 profile ID，清理只处理本账户生成的服务。TunnelOne 不记录密钥，统计使用 `wg show <name> latest-handshakes` / `transfer`，不调用会导出私钥的 `dump` 或 `showconf`。
- 卸载清理当前账户的 TunnelOne 服务，保留用户加密配置和独立的官方 WireGuard 安装。若使用过其他管理员账户，请先在相应账户退出 TunnelOne、断开连接。

## 开发、测试与发布

需要 Windows、.NET 10 SDK、PowerShell，以及生成安装包所用的 Inno Setup 6。无需 Xcode、Swift 或 macOS 的 Go bridge。

```powershell
dotnet build Windows/TunnelOne.Windows -c Release
dotnet run --project Windows/TunnelOne.Tests -c Release
# 管理员环境：安装官方依赖并测试实际服务/驱动，使用隔离的文档地址路由
./scripts/prepare-windows.ps1 -Architecture x64 -Install
dotnet run --project Windows/TunnelOne.Tests -c Release -- --integration
# UI 渲染检查，不连接 VPN、不读取用户配置
dotnet Windows/TunnelOne.Windows/bin/Release/net10.0-windows/TunnelOne.dll --smoke-test
./scripts/build-windows.ps1 -Architecture x64
./scripts/build-windows.ps1 -Architecture arm64
# 仅生成便携包
./scripts/build-windows.ps1 -Architecture x64 -SkipInstaller
```

依赖固定在 `scripts/windows-dependencies.lock.json`，下载时同时检查 SHA-256 与 WireGuard LLC Authenticode 签名。Windows 发布仅随包提供未修改的官方 MSI，不编译或签发自有内核驱动。上游源码见 [WireGuard for Windows v1.1.1](https://git.zx2c4.com/wireguard-windows/tag/?h=v1.1.1)，许可随包提供。

`build.yml` 在 main / PR / `v*` tag 调用 `windows.yml`。两个架构均运行配置、加密、生命周期测试和 x64 runner 上的真实隔离服务测试，编译并渲染原生窗口，随后交叉发布对应架构的自包含 ZIP、安装 EXE 和校验文件。检查最终 EXE 的 PE 架构，并对 x64 安装包执行静默安装、运行自包含应用渲染窗口及卸载。ARM64 产物已交叉编译；ARM64 实机、真实远端握手、代理客户端组合、休眠与网络切换仍需验收。

Tag 发布统一等待 macOS 与两个 Windows 构建通过，合并到同一个 GitHub Release。可手动运行 Windows 工作流，仅生成 artifact。

默认 Windows 应用和安装 EXE **未签名**。若有 Windows 代码签名证书，可在 GitHub Secrets 配置 `WINDOWS_CSC_LINK`（PFX 的 Base64）和 `WINDOWS_CSC_KEY_PASSWORD`，工作流会签名并时间戳验证应用和安装程序；不将证书提交到仓库。WireGuard 官方 MSI 的签名与 TunnelOne 自身签名是两回事。

实现依据：[官方服务与加密配置接口](https://git.zx2c4.com/wireguard-windows/about/docs/enterprise.md)、[Microsoft 系统代理 API](https://learn.microsoft.com/en-us/dotnet/api/system.net.webrequest.getsystemwebproxy?view=net-10.0)。
