namespace TunnelOne.Core;

public interface ITunnelBackend
{
    Task StartAsync(TunnelProfile profile);
    Task StopAsync(TunnelProfile profile);
    Task<bool> IsRunningAsync(TunnelProfile profile);
    Task<string> StatusAsync(TunnelProfile profile);
}

public interface IProxyGuard
{
    string Fingerprint();
    Task<string> VerifyAsync();
}

// Shared by UI and tests; serialize calls in the UI so a poll cannot race a stop.
public sealed class TunnelSession(ITunnelBackend backend, IProxyGuard proxy)
{
    public TunnelProfile? Active { get; private set; }
    public string ProxyReport { get; private set; } = "";
    private string fingerprint = "";
    public async Task ConnectAsync(TunnelProfile profile)
    {
        if (Active != null) throw new InvalidOperationException("请先断开当前隧道。");
        WireGuardConfig.Validate(profile.Config);
        if (profile.InheritProxy) ProxyReport = await proxy.VerifyAsync();
        // Mark ownership before installation, including partial installation failures.
        Active = profile;
        try
        {
            await backend.StartAsync(profile);
            if (!await backend.IsRunningAsync(profile)) throw new IOException("WireGuard 服务未运行。");
            if (profile.InheritProxy) ProxyReport = await proxy.VerifyAsync();
            else ProxyReport = "未执行代理检查；Windows 现有系统代理仍可能生效。";
            fingerprint = proxy.Fingerprint();
        }
        catch (Exception failure)
        {
            try { await DisconnectAsync(); }
            catch (Exception cleanup) { throw new AggregateException("连接失败且清理失败，请重试断开。", failure, cleanup); }
            throw;
        }
    }
    public async Task DisconnectAsync()
    {
        if (Active is not { } profile) return;
        await backend.StopAsync(profile);
        Active = null; // Keep ownership if removal failed, so the user can retry.
    }
    public async Task<string> RefreshAsync()
    {
        if (Active is not { } profile) return "未连接";
        try
        {
            if (!await backend.IsRunningAsync(profile)) throw new IOException("WireGuard 服务已停止。");
            var current = proxy.Fingerprint();
            if (profile.InheritProxy && current != fingerprint)
            {
                ProxyReport = await proxy.VerifyAsync();
                fingerprint = current;
            }
            return await backend.StatusAsync(profile);
        }
        catch
        {
            await DisconnectAsync();
            throw;
        }
    }
}
