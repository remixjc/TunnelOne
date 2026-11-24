using System.Diagnostics;
using System.Security.Cryptography;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;

namespace TunnelOne.Core;

public sealed class WireGuardBackend : ITunnelBackend
{
    public static string InstallDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WireGuard");
    public static bool IsInstalled => File.Exists(Path.Combine(InstallDirectory, "wireguard.exe")) && File.Exists(Path.Combine(InstallDirectory, "wg.exe"));
    private readonly string userId = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(WindowsIdentity.GetCurrent().User!.Value)))[..8].ToLowerInvariant();
    private readonly string runtime;
    public WireGuardBackend()
    {
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "TunnelOne");
        runtime = Path.Combine(root, userId);
    }
    public string NameFor(TunnelProfile profile) => "to-" + userId + "-" + profile.Id.ToString("N")[..16];
    private string PathFor(TunnelProfile profile) => Path.Combine(runtime, NameFor(profile) + ".conf.dpapi");
    private ServiceController? FindService(string name)
    {
        var service = new ServiceController("WireGuardTunnel$" + name);
        try { _ = service.Status; return service; }
        catch (InvalidOperationException error) when (error.InnerException is System.ComponentModel.Win32Exception { NativeErrorCode: 1060 })
        { service.Dispose(); return null; }
        catch { service.Dispose(); throw; }
    }
    private ServiceController? Service(TunnelProfile profile) => FindService(NameFor(profile));
    private void PrepareRuntime()
    {
        SecureStorage.CreatePrivateDirectory(Path.GetDirectoryName(runtime)!, false);
        SecureStorage.CreatePrivateDirectory(runtime, false);
    }

    public async Task StartAsync(TunnelProfile profile)
    {
        if (!IsInstalled) throw new IOException("请先安装 WireGuard for Windows 官方客户端。安装完成后重试。");
        PrepareRuntime();
        using var existing = Service(profile);
        if (existing != null) throw new IOException("此配置已有遗留服务，请先使用“清理遗留连接”。");
        var plain = Encoding.UTF8.GetBytes(WireGuardConfig.Validate(profile.Config));
        try { SecureStorage.WriteAtomic(PathFor(profile), SecureStorage.Protect(plain, NameFor(profile), true)); }
        finally { CryptographicOperations.ZeroMemory(plain); }
        await RunAsync("wireguard.exe", "/installtunnelservice", PathFor(profile));
        using var service = Service(profile) ?? throw new IOException("WireGuard 未创建隧道服务。");
        // Demand start prevents an unverified tunnel from reconnecting at boot after a crash.
        await RunExecutableAsync(Path.Combine(Environment.SystemDirectory, "sc.exe"), "config", service.ServiceName, "start=", "demand");
        await Task.Run(() => service.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(20)));
    }
    public async Task StopAsync(TunnelProfile profile)
    {
        bool exists;
        using (var service = Service(profile)) exists = service != null;
        if (exists)
        {
            await RunAsync("wireguard.exe", "/uninstalltunnelservice", NameFor(profile));
            for (int attempt = 0; attempt < 40; attempt++)
            {
                using var remaining = Service(profile);
                if (remaining == null) break;
                if (attempt == 39) throw new IOException("隧道服务尚未移除，请重试断开。");
                await Task.Delay(250);
            }
        }
        File.Delete(PathFor(profile));
    }
    public Task<bool> IsRunningAsync(TunnelProfile profile)
    {
        using var service = Service(profile);
        return Task.FromResult(service?.Status == ServiceControllerStatus.Running);
    }
    public async Task<string> StatusAsync(TunnelProfile profile)
    {
        // Never invoke 'dump' / 'showconf': those commands expose private/preshared keys.
        var handshakes = await RunAsync("wg.exe", "show", NameFor(profile), "latest-handshakes");
        var transfers = await RunAsync("wg.exe", "show", NameFor(profile), "transfer");
        var timestamps = handshakes.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(line => long.TryParse(line.Split('\t').Last().Trim(), out var value) ? value : 0).ToArray();
        var latest = timestamps.DefaultIfEmpty().Max();
        long received = 0, sent = 0;
        foreach (var line in transfers.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var fields = line.Trim().Split('\t');
            if (fields.Length == 3 && long.TryParse(fields[1], out var rx) && long.TryParse(fields[2], out var tx))
            { received += rx; sent += tx; }
        }
        var handshake = latest == 0 ? "尚无握手（服务运行不代表网络已通）" : $"最近握手 {Math.Max(0, DateTimeOffset.UtcNow.ToUnixTimeSeconds() - latest)} 秒前";
        return $"{handshake}\r\n对端 {timestamps.Length} · 接收 {received:N0} B · 发送 {sent:N0} B";
    }
    public async Task RecoverAsync()
    {
        PrepareRuntime();
        // Restrict cleanup to this Windows user's generated names, including deleted profile records.
        foreach (var path in Directory.EnumerateFiles(runtime, "to-" + userId + "-*.conf.dpapi"))
        {
            var name = Path.GetFileName(path)[..^11];
            if (!System.Text.RegularExpressions.Regex.IsMatch(name, "^to-" + userId + "-[a-f0-9]{16}$")) continue;
            bool exists;
            using (var service = FindService(name)) exists = service != null;
            if (exists) await RunAsync("wireguard.exe", "/uninstalltunnelservice", name);
            File.Delete(path);
        }
    }
    private static Task<string> RunAsync(string file, params string[] arguments) => RunExecutableAsync(Path.Combine(InstallDirectory, file), arguments);
    private static async Task<string> RunExecutableAsync(string path, params string[] arguments)
    {
        var info = new ProcessStartInfo(path) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        using var process = Process.Start(info) ?? throw new IOException("无法启动 WireGuard 命令。");
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        try { await process.WaitForExitAsync(timeout.Token); }
        catch (OperationCanceledException) { process.Kill(true); throw new IOException("WireGuard 命令超时。"); }
        await Task.WhenAll(output, error);
        // CLI errors can contain configuration contents. Keep them out of UI/logs.
        if (process.ExitCode != 0) throw new IOException($"{Path.GetFileName(path)} 操作失败（代码 {process.ExitCode}）。请查看 WireGuard 官方诊断日志。");
        return output.Result;
    }
}
