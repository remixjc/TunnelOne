using TunnelOne.Core;

namespace TunnelOne.Windows;

internal sealed class ProfileEditor : Form
{
    public TunnelProfile? Result { get; private set; }
    public ProfileEditor(TunnelProfile profile)
    {
        Text = "WireGuard 配置 · 包含私钥";
        Size = new Size(760, 640);
        MinimumSize = new Size(500, 400);
        StartPosition = FormStartPosition.CenterParent;
        Font = new Font("Microsoft YaHei UI", 10);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(16), RowCount = 4, ColumnCount = 1 };
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        var name = new TextBox { Text = profile.Name, Dock = DockStyle.Top, MaxLength = 100 };
        var config = new TextBox { Text = profile.Config.ReplaceLineEndings(), Multiline = true, AcceptsTab = true, AcceptsReturn = true,
            ScrollBars = ScrollBars.Both, WordWrap = false, Dock = DockStyle.Fill, Font = new Font("Consolas", 11), MaxLength = WireGuardConfig.MaxBytes };
        var save = new Button { Text = "验证并保存", AutoSize = true, Padding = new Padding(8) };
        save.Click += (_, _) =>
        {
            try
            {
                if (string.IsNullOrWhiteSpace(name.Text)) throw new FormatException("请填写隧道名称。");
                Result = profile with { Name = name.Text.Trim(), Config = WireGuardConfig.Validate(config.Text) };
                DialogResult = DialogResult.OK;
            }
            catch (FormatException error) { MessageBox.Show(this, error.Message, "配置错误"); }
        };
        layout.Controls.Add(new Label { Text = "隧道名称 · 不支持 PreUp / PostUp 等脚本", AutoSize = true }, 0, 0);
        layout.Controls.Add(name, 0, 1);
        layout.Controls.Add(config, 0, 2);
        layout.Controls.Add(save, 0, 3);
        Controls.Add(layout);
    }
}
