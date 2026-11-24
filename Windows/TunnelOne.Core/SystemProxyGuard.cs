using Microsoft.Win32;
using System.Net;

namespace TunnelOne.Core;

public sealed class SystemProxyGuard : IProxyGuard
{
    private const string Settings = @"Software\Microsoft\Windows\CurrentVersion\Internet Settings";
    public string Fingerprint()
    {
        using var key = Registry.CurrentUser.OpenSubKey(Settings);
        using var connections = key?.OpenSubKey("Connections");
        // The connection blob includes auto-detection and policy-dependent LAN settings.
        return string.Join("|", new[] { "ProxyEnable", "ProxyServer", "ProxyOverride", "AutoConfigURL", "AutoDetect" }
            .Select(name => Convert.ToString(key?.GetValue(name)))) + "|" +
            Convert.ToHexString(connections?.GetValue("DefaultConnectionSettings") as byte[] ?? []);
    }
    public async Task<string> VerifyAsync()
    {
        using var key = Registry.CurrentUser.OpenSubKey(Settings);
        using var connections = key?.OpenSubKey("Connections");
        var blob = connections?.GetValue("DefaultConnectionSettings") as byte[];
        bool pac = !string.IsNullOrWhiteSpace(key?.GetValue("AutoConfigURL") as string);
        bool automatic = pac ||
            Convert.ToInt32(key?.GetValue("AutoDetect") ?? 0) != 0 || blob is { Length: > 8 } && (blob[8] & 12) != 0;
        bool manual = Convert.ToInt32(key?.GetValue("ProxyEnable") ?? 0) != 0;
        // Windows enables WPAD auto-detection by default even on networks with no proxy.
        // Do not make an intranet-only tunnel depend on public HTTPS in that default state.
        if (!manual && !pac) return automatic
            ? "仅启用自动发现（WPAD），本次未验证代理；仅连接 WireGuard。"
            : "未启用系统代理，本次仅连接 WireGuard。";
        if (manual && string.IsNullOrWhiteSpace(key?.GetValue("ProxyServer") as string))
            throw new IOException("系统手动代理已启用，但服务器地址为空。请先修正系统代理。");
        // A fresh system proxy object observes the user's latest PAC/bypass/server settings.
        // Do not change HKCU, WinHTTP or any other application's global proxy settings.
        var systemProxy = WebRequest.GetSystemWebProxy();
        using var proxyLifetime = systemProxy as IDisposable;
        using var handler = new HttpClientHandler { Proxy = systemProxy, UseProxy = true };
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(15) };
        try
        {
            using var response = await client.GetAsync("https://www.google.com/generate_204", HttpCompletionOption.ResponseHeadersRead);
            if (response.StatusCode != HttpStatusCode.NoContent)
                throw new HttpRequestException("系统代理检查目标未返回预期的 HTTP 204。");
            return "系统代理规则 HTTPS 检查通过（含 PAC / 绕过规则；规则可能选择直连）。";
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException)
        { throw new IOException("系统代理 HTTPS 检查失败。请先确认代理客户端可用；本次隧道将回滚。", error); }
    }
}
