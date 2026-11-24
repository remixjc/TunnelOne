using System.Diagnostics;
using System.Reflection;
using System.Text;
using TunnelOne.Core;

namespace TunnelOne.Windows;

public sealed class MainForm : Form
{
    private readonly ProfileStore store;
    private readonly WireGuardBackend backend = new();
    private readonly TunnelSession session;
    private readonly ListBox tunnels = new() { Dock = DockStyle.Fill, IntegralHeight = false, BorderStyle = BorderStyle.None };
    private readonly Label heading = new() { Text = "准备好，即可出发", AutoSize = true, Font = new Font("Microsoft YaHei UI", 22, FontStyle.Bold) };
    private readonly Label status = new() { Text = "导入 WireGuard 配置，开始你的第一次连接。", AutoSize = true, MaximumSize = new Size(640, 0) };
    private readonly Label details = new() { AutoSize = true, MaximumSize = new Size(640, 0) };
    private readonly CheckBox inherit = new() { Text = "连接时沿用系统代理（连接前后检查可用性）", AutoSize = true, Checked = true };
    private readonly Button connect = new() { Text = "连接隧道", AutoSize = true, Height = 44 };
    private readonly TextBox log = new() { Multiline = true, ReadOnly = true, Dock = DockStyle.Fill, ScrollBars = ScrollBars.Vertical, BorderStyle = BorderStyle.FixedSingle };
    private readonly FlowLayoutPanel actions = new() { Dock = DockStyle.Fill, AutoSize = true, WrapContents = true };
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 4000 };
    private readonly NotifyIcon tray = new() { Text = "TunnelOne · 隧行", Icon = SystemIcons.Shield, Visible = true };
    private bool busy, closing;
    private TunnelProfile? Selected => tunnels.SelectedItem as TunnelProfile;

    public MainForm(bool smoke = false)
    {
        store = new(smoke ? Path.Combine(AppContext.BaseDirectory, "smoke-profiles") : null);
        session = new(backend, new SystemProxyGuard());
        Text = "TunnelOne · 隧行  " + Assembly.GetExecutingAssembly().GetName().Version?.ToString(3);
        Font = new Font("Microsoft YaHei UI", 10);
        BackColor = ColorTranslator.FromHtml("#f6f7f9");
        ForeColor = ColorTranslator.FromHtml("#24262b");
        MinimumSize = new Size(960, 680);
        Size = new Size(1100, 780);
        StartPosition = FormStartPosition.CenterScreen;
        Icon = SystemIcons.Shield;
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, Padding = new Padding(20) };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 235));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        var sidebar = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 3, Padding = new Padding(0, 0, 18, 0) };
        sidebar.RowStyles.Add(new RowStyle(SizeType.Absolute, 70));
        sidebar.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        sidebar.RowStyles.Add(new RowStyle(SizeType.Absolute, 65));
        sidebar.Controls.Add(new Label { Text = "TunnelOne\n隧行 · 我的隧道", AutoSize = true, Font = new Font(Font, FontStyle.Bold) }, 0, 0);
        tunnels.BackColor = BackColor;
        tunnels.Font = new Font(Font.FontFamily, 12);
        tunnels.SelectedIndexChanged += (_, _) => ShowSelection();
        sidebar.Controls.Add(tunnels, 0, 1);
        var import = Button("＋ 导入 .conf / ZIP", ImportAsync);
        import.Dock = DockStyle.Fill;
        sidebar.Controls.Add(import, 0, 2);
        var main = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 8, ColumnCount = 1, Padding = new Padding(18), BackColor = Color.White };
        for (int i = 0; i < 7; i++) main.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        main.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        heading.Margin = new Padding(0, 5, 0, 16);
        main.Controls.Add(heading, 0, 0);
        status.Margin = new Padding(0, 0, 0, 18);
        main.Controls.Add(status, 0, 1);
        connect.Padding = new Padding(20, 8, 20, 8);
        connect.BackColor = ColorTranslator.FromHtml("#465fff");
        connect.ForeColor = Color.White;
        connect.FlatStyle = FlatStyle.Flat;
        connect.Click += async (_, _) => await ExecuteAsync(ToggleAsync);
        main.Controls.Add(connect, 0, 2);
        inherit.Margin = new Padding(0, 18, 0, 18);
        inherit.CheckedChanged += (_, _) =>
        {
            if (Selected is { } p && session.Active == null && !busy && p.InheritProxy != inherit.Checked)
                _ = ExecuteAsync(() => { store.Save(p with { InheritProxy = inherit.Checked }); Reload(p.Id); return Task.CompletedTask; });
        };
        main.Controls.Add(inherit, 0, 3);
        main.Controls.Add(details, 0, 4);
        actions.Margin = new Padding(0, 15, 0, 15);
        actions.Controls.Add(Button("新建", () => EditAsync(true)));
        actions.Controls.Add(Button("编辑", () => EditAsync(false)));
        actions.Controls.Add(Button("导出", ExportAsync));
        actions.Controls.Add(Button("删除", DeleteAsync));
        actions.Controls.Add(Button("清理遗留连接", async () => { await backend.RecoverAsync(); AddLog("已清理本用户的 TunnelOne 遗留服务。"); }));
        actions.Controls.Add(Button("安装 WireGuard", () => { Open("https://www.wireguard.com/install/"); return Task.CompletedTask; }));
        main.Controls.Add(actions, 0, 5);
        main.Controls.Add(new Label { Text = "连接日志 · 不记录密钥\n关闭窗口会断开隧道；最小化后可从托盘恢复。", AutoSize = true, Margin = new Padding(0, 0, 0, 8) }, 0, 6);
        main.Controls.Add(log, 0, 7);
        layout.Controls.Add(sidebar, 0, 0);
        layout.Controls.Add(main, 1, 0);
        Controls.Add(layout);
        var menu = new ContextMenuStrip();
        menu.Items.Add("打开 TunnelOne", null, (_, _) => Restore());
        menu.Items.Add("连接 / 断开", null, async (_, _) => await ExecuteAsync(ToggleAsync));
        menu.Items.Add("断开并退出", null, (_, _) => Close());
        tray.ContextMenuStrip = menu;
        tray.DoubleClick += (_, _) => Restore();
        Resize += (_, _) => { if (WindowState == FormWindowState.Minimized) Hide(); };
        FormClosing += OnClosing;
        timer.Tick += async (_, _) =>
        {
            if (session.Active == null || busy) return;
            await ExecuteAsync(async () => { details.Text = await session.RefreshAsync(); status.Text = session.ProxyReport; });
        };
        Reload();
        if (!smoke) Shown += async (_, _) => await ExecuteAsync(async () =>
        {
            await backend.RecoverAsync();
            AddLog("已检查并清理本用户上次异常退出留下的 TunnelOne 连接。");
        });
        if (!WireGuardBackend.IsInstalled) AddLog("尚未安装官方 WireGuard for Windows。点击“安装 WireGuard”，完成后可直接连接。");
        AddLog("Windows 使用已有用户系统代理，不修改全局代理。PAC / 绕过规则可能选择直连；忽略系统代理的应用不受此检查保证。");
        timer.Start();
    }

    private Button Button(string text, Func<Task> action)
    {
        var button = new Button { Text = text, AutoSize = true, Padding = new Padding(5), Margin = new Padding(0, 0, 6, 6) };
        button.Click += async (_, _) => await ExecuteAsync(action);
        return button;
    }
    private void Reload(Guid? selected = null)
    {
        var profiles = store.Load(); // Corrupt encrypted records fail visibly; never silently discard keys.
        tunnels.DataSource = profiles.ToList();
        if (selected.HasValue) tunnels.SelectedItem = profiles.FirstOrDefault(p => p.Id == selected);
        ShowSelection();
    }
    private void ShowSelection()
    {
        heading.Text = session.Active?.Name ?? Selected?.Name ?? "准备好，即可出发";
        inherit.Enabled = session.Active == null && !busy;
        if (Selected is { } p) inherit.Checked = p.InheritProxy;
        connect.Text = session.Active == null ? "连接隧道" : "断开隧道";
        connect.Enabled = !busy && (session.Active != null || Selected != null);
        actions.Enabled = !busy && session.Active == null;
        tunnels.Enabled = !busy && session.Active == null;
    }
    private async Task ExecuteAsync(Func<Task> action)
    {
        if (busy) return;
        busy = true;
        ShowSelection();
        try { await action(); }
        catch (Exception error)
        {
            status.Text = error.Message;
            AddLog(error.Message);
            MessageBox.Show(this, error.Message, "TunnelOne", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally { busy = false; ShowSelection(); }
    }
    private async Task ToggleAsync()
    {
        if (session.Active != null)
        {
            await session.DisconnectAsync();
            status.Text = "已断开；用户系统代理保持当前设置。";
            details.Text = "";
            AddLog("已断开 WireGuard 隧道。");
        }
        else if (Selected is { } profile)
        {
            status.Text = "正在检查代理并启动 WireGuard…";
            await session.ConnectAsync(profile);
            status.Text = session.ProxyReport;
            details.Text = await session.RefreshAsync();
            AddLog("WireGuard 服务已运行。" + session.ProxyReport);
        }
    }
    private Task ImportAsync()
    {
        if (session.Active != null) throw new InvalidOperationException("导入前请先断开连接。");
        using var dialog = new OpenFileDialog { Filter = "WireGuard 配置|*.conf;*.zip", Multiselect = true };
        if (dialog.ShowDialog(this) != DialogResult.OK) return Task.CompletedTask;
        var imported = dialog.FileNames.SelectMany(ProfileStore.Import).ToArray(); // Validate all before saving any.
        foreach (var profile in imported) store.Save(profile);
        Reload(imported.LastOrDefault()?.Id);
        AddLog($"已导入 {imported.Length} 个配置，并使用 Windows DPAPI 加密保存。");
        return Task.CompletedTask;
    }
    private Task EditAsync(bool create)
    {
        if (!create && Selected == null) return Task.CompletedTask;
        var profile = create ? new TunnelProfile(Guid.NewGuid(), "新隧道", "[Interface]\r\nPrivateKey = \r\nAddress = 10.0.0.2/32\r\n\r\n[Peer]\r\nPublicKey = \r\nAllowedIPs = 10.0.0.0/24\r\nEndpoint = vpn.example.com:51820\r\n") : Selected!;
        using var editor = new ProfileEditor(profile);
        if (editor.ShowDialog(this) == DialogResult.OK) { store.Save(editor.Result!); Reload(profile.Id); }
        return Task.CompletedTask;
    }
    private Task ExportAsync()
    {
        if (Selected is not { } profile) return Task.CompletedTask;
        if (MessageBox.Show(this, "导出的标准 .conf 包含明文私钥和预共享密钥，请妥善保存。继续导出？", "导出敏感配置", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK) return Task.CompletedTask;
        using var dialog = new SaveFileDialog { Filter = "WireGuard 配置|*.conf", FileName = string.Concat(profile.Name.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '_' : c)) + ".conf" };
        if (dialog.ShowDialog(this) == DialogResult.OK) File.WriteAllText(dialog.FileName, profile.Config, new UTF8Encoding(false));
        return Task.CompletedTask;
    }
    private Task DeleteAsync()
    {
        if (Selected is { } profile && MessageBox.Show(this, "删除此隧道的本机配置？", "删除隧道", MessageBoxButtons.OKCancel) == DialogResult.OK)
        { store.Delete(profile.Id); Reload(); }
        return Task.CompletedTask;
    }
    private async void OnClosing(object? sender, FormClosingEventArgs e)
    {
        if (closing) return;
        e.Cancel = true;
        if (busy) return;
        await ExecuteAsync(async () => { await session.DisconnectAsync(); closing = true; });
        if (closing) { timer.Stop(); tray.Visible = false; BeginInvoke(Close); }
    }
    private void AddLog(string message) => log.AppendText($"{DateTime.Now:HH:mm:ss}  {message}\r\n");
    private void Restore() { Show(); WindowState = FormWindowState.Normal; Activate(); }
    private static void Open(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
    protected override void Dispose(bool disposing)
    {
        if (disposing) { timer.Dispose(); tray.Dispose(); }
        base.Dispose(disposing);
    }
}
