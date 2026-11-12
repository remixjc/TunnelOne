# v0.2.1 原型与安全启动 command 的实现对照

本次修订以用户指出的两个问题为范围：主窗口未按原型实现；开启后缺少 `local/legacy-tools/WireGuard与Clash安全启动.command` 中的实际操作。该 command 保持原样，作为行为对照。

## 界面

主窗口复用原型 CSS 和结构：208px 侧栏、隧道列表、概览 / 隧道配置 / 按需连接标签页、连接按钮、代理开关、网络信息、握手与收发统计、代理配置 / 日志 / 设置导航。WebKit 只加载应用内资源，通过限定的消息桥调用原生隧道管理器；页面不访问网络，也没有连接计时器或预设成功结果。

隧道列表、配置、状态、统计、检查结果均由原生代码提供。导入、编辑、导出、删除继续使用现有的系统文件选择器及原生编辑窗口。私钥不传给页面。原型里的样本隧道、节点、时延和流量不会进入应用数据。

默认代理为现有 Clash Party 的 `127.0.0.1:7890`。打开隧道的代理开关后即可使用，不需要导入 YAML 或重新配置节点。历史内置模式仍可运行，关闭后重新打开代理开关会保存为 Clash Party 模式。

## command 操作对照

| command 的操作 | 应用中的实现 |
| --- | --- |
| 检查 `sysProxy.enable`、`tun.enable`、`mixed-port`、`mode` | 扩展启动适配器前读取对应用户的 Clash Party 两个配置文件，并按 command 的条件验证 |
| 拒绝主网络已经被其它 utun 接管 | 从系统动态配置读取主服务及接口，检查失败时不建立本次隧道 |
| 确认全局生效 HTTP / HTTPS / SOCKS 均为 127.0.0.1:7890 | 只检查顶层代理字典，不能用 `__SCOPED__` 中的 Wi-Fi 配置冒充全局代理 |
| 从 State 或 Setup 找到可复制的代理 | 先读 State，再读 Setup，保存验证通过的物理网络代理快照 |
| `sudo -v` | 由已授权的系统扩展完成特权操作，不打开终端或另行采集管理员密码 |
| `open -g -a "Clash Party"` | 主窗口及菜单栏路径通过 NSWorkspace 在后台打开现有 Clash Party |
| 启动 WireGuard 并等待状态 | 使用应用中选定的真实隧道与 WireGuardAdapter，避免同时启动原 WireGuard 应用中的同名隧道 |
| 检查 1.1.1.1 路由 | 查询真实 IPv4 路由，必须属于本次 adapter 返回的 utun |
| 确认临时主服务属于目标 WireGuard | 主接口必须等于本次 utun，服务 ID 不能等于原物理网络 |
| 同步隧道代理 | 用系统配置 API 写本次 `State:/Network/Service/<ID>/Proxies`；不写 Setup 或永久网络偏好 |
| 重新核验生效代理 | 最多检查 12 次，每次间隔 250ms；仍未生效则回滚 |
| 两项并行 curl | 百度明确禁用代理；Google 明确使用 127.0.0.1:7890；均按退出状态和 HTTP 200–399 判断 |
| 检查失败自动断开 | provider 停止本次 WireGuardAdapter；记录实际回滚完成或失败，保留原有 Clash |
| JSON 报告 | 根目录按 UID 隔离的配置旁保存 0600 报告，经认证 XPC 提供给主窗口 |
| 只检查启动，不持续监控 | 保持相同范围；窗口刷新状态与统计，不后台反复探测或重新连接 |

固定隧道名改为用户在界面中选择的已导入隧道；不会自动改写其 AllowedIPs、服务器或密钥。该安全启动流程要求 IPv4 主路由确实由本次隧道接管。仅内网路由可在关闭代理开关时使用。

原型展示完整产品方向，但本次没有新增订阅、节点管理、测速或全应用 TUN。使用已有 Clash Party 的配置和规则。

## 验证与边界

- Swift 测试覆盖默认设置、Clash 前置条件、State / Setup 回退、顶层代理与 scoped 代理区别、目标接口归属、写入失败、两项检查与任一失败、取消、报告权限和 UID 隔离。
- 界面测试确认按钮发送原生动作、未收到真实结果时不能显示成功、真实报告驱动进度 / 检查结果、缺失遥测显示空值、失败回滚展示和 HTML 转义。
- 应用及系统扩展进行 arm64 / x86_64 编译，另在 macOS WKWebView 中检查本地资源与桥接。
- 本次修订未在正在使用的网络上自动替换扩展或执行真实断网 / 回滚验收。此前 v0.2.0 的连接成功记录不能代替这次新流程的联网验收。

## 本机安装验证

2026-11-12，确认两条 VPN 均已断开、TunnelOne 按需连接关闭后，备份旧应用并尝试安装 build 4。Developer ID 签名、profiles 和 bundle 校验通过，但 macOS 系统扩展验证拒绝了新扩展；日志包含 `Error checking with notarization daemon: 3` 和代码要求不满足 `-67050`。系统仍保留 build 3。

本机没有 `TunnelOne-notarization` 钥匙串凭据，也没有公证环境变量，不能在本机完成新的 Apple 公证。可安装版本仍需经过仓库已有 `build.yml` 的 `require_signed` 路径，完成公证和 staple 后再安装验证。启动外部代理连接前已增加对当前 build 的版本化 XPC 安全报告 API 的探测，不能在新扩展缺失时退回旧的端口检查流程。

验证失败后已从 `local/backups/TunnelOne-0.2.0-build3-before-command-alignment.app` 恢复原安装，系统扩展仍为 build 3，两条 VPN 均保持断开。本次没有发起真实连接，也未修改系统安全设置；修正版 build 4 保留在 `build/DerivedData/Build/Products/Release/TunnelOne.app`。
