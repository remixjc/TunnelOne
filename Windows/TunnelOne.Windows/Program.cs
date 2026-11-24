using System.Security.Principal;

namespace TunnelOne.Windows;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        using var identity = WindowsIdentity.GetCurrent();
        var sid = identity.User!.Value;
        using var mutex = new Mutex(true, @"Global\TunnelOne-" + sid, out bool first);
        if (!first) { MessageBox.Show("TunnelOne 已运行，请检查任务栏或托盘。", "TunnelOne"); return; }
        bool smoke = args.Contains("--smoke-test");
        if (!smoke && !new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))
        { MessageBox.Show("请以管理员身份运行 TunnelOne，以管理 WireGuard 隧道服务。", "TunnelOne"); return; }
        try
        {
            if (args.Contains("--cleanup")) { new TunnelOne.Core.WireGuardBackend().RecoverAsync().GetAwaiter().GetResult(); return; }
            using var form = new MainForm(smoke);
            if (smoke)
                form.Shown += (_, _) => form.BeginInvoke(() =>
                {
                    using var bitmap = new Bitmap(form.Width, form.Height);
                    form.DrawToBitmap(bitmap, new Rectangle(0, 0, form.Width, form.Height));
                    bitmap.Save(Path.Combine(AppContext.BaseDirectory, "smoke-test.png"));
                    form.Close();
                });
            Application.Run(form);
        }
        catch (Exception error)
        { MessageBox.Show("启动失败：" + error.Message, "TunnelOne", MessageBoxButtons.OK, MessageBoxIcon.Error); Environment.ExitCode = 1; }
        finally { mutex.ReleaseMutex(); }
    }
}
