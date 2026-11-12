# v0.3.0 系统代理继承

## 用户行为

用户先在自己的代理客户端中启用系统代理，再连接 TunnelOne。TunnelOne 根据 macOS 当前生效设置决定是否带入代理，不识别客户端名称、不读取私有配置、不启动客户端，不限定端口或规则模式。

新导入隧道默认开启「连接时沿用系统代理」，已有隧道保留偏好。开关关闭时仅应用 WireGuard 配置，不主动同步代理；原有系统代理仍可能生效。历史内置 Mihomo 模式保留兼容。

## 连接流程

1. 从 SCDynamicStore 读取主网络服务、接口与顶层生效代理。拒绝将现有 utun 主网络当作普通系统代理来源，避免盲目叠加 TUN / VPN。
2. 规范化 HTTP、HTTPS、SOCKS 各自的主机与端口，保存 PAC URL / 内联脚本、例外列表和简单主机绕过选项。忽略禁用的旧字段和 `__SCOPED__`；启用但无效的字段明确报错。WPAD 尚不支持。
3. 代理存在时，使用 ephemeral URLSession 的 connectionProxyDictionary 验证快照规则下的 HTTPS 请求。由 CFNetwork 处理协议、PAC 与绕过选择；PAC 返回 DIRECT 是合法规则，不强制改写为代理。
4. 启动 WireGuardAdapter，通过 NEProxySettings 应用 HTTP / HTTPS / PAC。适配器就绪后先完成 provider 启动回调，让系统进入 Connected，再等待一秒稳定期。
5. 根据本次 utun 的 IPv4 / IPv6 服务字典定位临时服务，不能使用物理网络服务或仅凭固定 VPN 名称判断归属。NEProxySettings 没有 SOCKS 字段，因此将完整规范代理字典同步到该临时 State 服务。
6. 核对顶层生效代理与快照相等，再使用未强制指定代理字典的 URLSession 请求 Google，记录实际系统规则访问与代理 / DIRECT 指标。不能仅凭显式指定端口的 curl 成功判定继承成功。
7. IPv4 全隧道同时执行绑定本次接口的百度 HTTPS 直连检查；仅内网路由跳过公网直连要求，不改写 AllowedIPs。没有系统代理时不发起代理检查，报告 `connected-without-proxy`。
8. 配置、同步或访问失败时保存原因并回滚本次 WireGuard；成功报告 `connected-and-checked`。Connected、握手和访问通过是不同状态，界面仅按真实数据展示。

## 配置变化与所有权

监听物理网络服务的 State / Setup 代理、IPv4 服务与服务顺序变化。以活跃物理网络及服务顺序选择来源，不使用本次 VPN 的生效字典作为新来源。记录来源原值，避免无关通知把全局策略误换成空配置。启动验证后立即补一次来源核对，覆盖验证期间的变化。

变更合并后串行更新适配器代理设置，并重新验证临时字典与实际系统访问。监听自身写入产生的通知时，来源不变且生效值匹配则不写入，避免循环。来源网络暂不可用时等待后续通知；无效或不可用的新代理触发回滚。

只写 `State:/Network/Service/<本次服务>/Proxies`，不写物理网络、Setup 或永久偏好。断开停止观察与未完成任务，由系统移除本次隧道设置，不把连接前快照写回并覆盖用户后来的修改。

## 边界与验证

- 系统代理只影响遵循它的应用，不代表全应用或 UDP 代理，也不保证代理节点的出站全部经过 WireGuard。
- PAC 支持明确的 HTTP / HTTPS URL 与内联脚本；WPAD、文件 PAC、额外代理认证及独立 TUN / VPN 共存不承诺自动兼容。
- 目前访问目标固定为 Google generate_204；IPv4 全隧道的直连目标为百度。目标故障可能使检查失败。
- macOS 15+ 直连检查绑定 virtualInterface 并绕过代理；macOS 13/14 保留旧兼容探测路径，仍需实机验收。
- 本地网络测试启动真正的 HTTP / SOCKS 服务，使用不可解析域名，确认 HTTP、SOCKS、PAC 请求到达配置代理且绕过规则被执行；不以模拟返回值替代协议验证。
- 同一标准系统代理入口的兼容性不等于逐个客户端实测。当前机器上的安装与联网结果记录在 acceptance.md。
