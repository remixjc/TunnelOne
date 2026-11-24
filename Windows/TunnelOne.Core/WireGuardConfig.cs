using System.Net;

namespace TunnelOne.Core;

// Keep the original portable text, but never allow wg-quick hooks to execute as SYSTEM.
public static class WireGuardConfig
{
    public const int MaxBytes = 1024 * 1024;
    public static string Validate(string text)
    {
        if (System.Text.Encoding.UTF8.GetByteCount(text) > MaxBytes || text.Contains('\0'))
            throw new FormatException("配置过大或包含无效字符。");
        string section = "";
        var keys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        bool hasInterface = false, hasPeer = false;
        foreach (var source in text.Split('\n'))
        {
            var line = source.Split('#')[0].Trim();
            if (line.Length == 0) continue;
            if (line.StartsWith('['))
            {
                CheckRequired();
                if (line.Equals("[Interface]", StringComparison.OrdinalIgnoreCase) && !hasInterface && !hasPeer)
                { section = "Interface"; hasInterface = true; }
                else if (line.Equals("[Peer]", StringComparison.OrdinalIgnoreCase) && hasInterface)
                { section = "Peer"; hasPeer = true; }
                else throw new FormatException("仅支持一个 [Interface] 及其后的 [Peer]。");
                keys.Clear();
                continue;
            }
            var pair = line.Split('=', 2, StringSplitOptions.TrimEntries);
            if (pair.Length != 2 || pair[1].Length == 0 || section.Length == 0)
                throw new FormatException("配置必须是有效的 WireGuard INI 文本。");
            var key = pair[0];
            string[] allowed = section == "Interface"
                ? ["PrivateKey", "Address", "DNS", "ListenPort", "MTU"]
                : ["PublicKey", "PresharedKey", "AllowedIPs", "Endpoint", "PersistentKeepalive"];
            if (!allowed.Contains(key, StringComparer.OrdinalIgnoreCase))
                throw new FormatException("存在不支持的配置项。不允许运行脚本或修改全局设置。");
            if (!keys.Add(key) && !new[] { "Address", "DNS", "AllowedIPs" }.Contains(key, StringComparer.OrdinalIgnoreCase))
                throw new FormatException($"配置项重复：{key}。");
            var value = pair[1];
            if (key.EndsWith("Key", StringComparison.OrdinalIgnoreCase))
            {
                byte[] bytes;
                try { bytes = Convert.FromBase64String(value); }
                catch (FormatException) { throw new FormatException($"{key} 必须是 32 字节的 Base64 密钥。"); }
                if (bytes.Length != 32 || bytes.All(b => b == 0))
                    throw new FormatException($"{key} 必须是有效的 32 字节密钥。");
            }
            if (key.Equals("Address", StringComparison.OrdinalIgnoreCase) || key.Equals("AllowedIPs", StringComparison.OrdinalIgnoreCase))
                foreach (var cidr in value.Split(',', StringSplitOptions.TrimEntries))
                {
                    var parts = cidr.Split('/');
                    if (parts.Length != 2 || !IPAddress.TryParse(parts[0], out var ip) ||
                        !int.TryParse(parts[1], out var prefix) || prefix < 0 || prefix > ip.GetAddressBytes().Length * 8)
                        throw new FormatException($"{key} 必须包含有效的 CIDR 地址。");
                }
            if (new[] { "ListenPort", "MTU", "PersistentKeepalive" }.Contains(key, StringComparer.OrdinalIgnoreCase) &&
                (!ushort.TryParse(value, out var number) || key.Equals("MTU", StringComparison.OrdinalIgnoreCase) && number < 576))
                throw new FormatException($"{key} 数值无效。");
        }
        CheckRequired();
        if (!hasInterface || !hasPeer) throw new FormatException("配置需要 [Interface] 与至少一个 [Peer]。");
        return text.Trim() + "\n";

        void CheckRequired()
        {
            if (section == "Interface" && !keys.Contains("PrivateKey")) throw new FormatException("缺少 PrivateKey。");
            if (section == "Peer" && (!keys.Contains("PublicKey") || !keys.Contains("AllowedIPs")))
                throw new FormatException("每个 Peer 需要 PublicKey 与 AllowedIPs。");
        }
    }
}
