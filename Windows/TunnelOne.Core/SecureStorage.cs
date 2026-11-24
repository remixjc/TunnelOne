using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

namespace TunnelOne.Core;

public static class SecureStorage
{
    [StructLayout(LayoutKind.Sequential)]
    private struct Blob { public int Length; public IntPtr Data; }
    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CryptProtectData(ref Blob input, string description, IntPtr entropy,
        IntPtr reserved, IntPtr prompt, int flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError = true)]
    private static extern bool CryptUnprotectData(ref Blob input, IntPtr description, IntPtr entropy,
        IntPtr reserved, IntPtr prompt, int flags, out Blob output);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);

    public static byte[] Protect(byte[] data, string description, bool machine = false) => Transform(data, description, machine, false);
    public static byte[] Unprotect(byte[] data) => Transform(data, "", false, true);
    private static byte[] Transform(byte[] data, string description, bool machine, bool decrypt)
    {
        var input = new Blob { Length = data.Length, Data = Marshal.AllocHGlobal(data.Length) };
        Blob output = default;
        try
        {
            Marshal.Copy(data, 0, input.Data, data.Length);
            bool ok = decrypt
                ? CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output)
                : CryptProtectData(ref input, description, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1 | (machine ? 4 : 0), out output);
            if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error());
            var result = new byte[output.Length];
            Marshal.Copy(output.Data, result, 0, result.Length);
            return result;
        }
        finally
        {
            for (int i = 0; i < input.Length; i++) Marshal.WriteByte(input.Data, i, 0);
            Marshal.FreeHGlobal(input.Data);
            if (output.Data != IntPtr.Zero)
            {
                for (int i = 0; i < output.Length; i++) Marshal.WriteByte(output.Data, i, 0);
                LocalFree(output.Data);
            }
        }
    }

    public static void CreatePrivateDirectory(string path, bool userAccess)
    {
        var full = Path.GetFullPath(path);
        for (var ancestor = new DirectoryInfo(full); ancestor != null; ancestor = ancestor.Parent)
            if (ancestor.Exists && (ancestor.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("配置目录不能是符号链接或重解析点。");
        var acl = new DirectorySecurity();
        acl.SetAccessRuleProtection(true, false);
        var identities = new List<SecurityIdentifier> {
            new(WellKnownSidType.LocalSystemSid, null), new(WellKnownSidType.BuiltinAdministratorsSid, null) };
        if (userAccess) identities.Add(WindowsIdentity.GetCurrent().User!);
        foreach (var sid in identities)
            acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        var directory = new DirectoryInfo(full);
        directory.Create(acl);
        directory.SetAccessControl(acl);
    }

    public static void WriteAtomic(string path, byte[] bytes)
    {
        var temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try { File.WriteAllBytes(temporary, bytes); File.Move(temporary, path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}

public sealed record TunnelProfile(Guid Id, string Name, string Config, bool InheritProxy = true)
{
    public override string ToString() => Name;
}

public sealed class ProfileStore
{
    public string DirectoryPath { get; }
    public ProfileStore(string? directory = null)
    {
        DirectoryPath = directory ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TunnelOne", "Profiles");
        SecureStorage.CreatePrivateDirectory(DirectoryPath, true);
    }
    public IReadOnlyList<TunnelProfile> Load() => Directory.EnumerateFiles(DirectoryPath, "*.profile")
        .Select(path => JsonSerializer.Deserialize<TunnelProfile>(SecureStorage.Unprotect(File.ReadAllBytes(path)))
            ?? throw new InvalidDataException("配置存储损坏。"))
        .Select(p => p with { Config = WireGuardConfig.Validate(p.Config) }).OrderBy(p => p.Name).ToArray();
    public void Save(TunnelProfile profile)
    {
        if (string.IsNullOrWhiteSpace(profile.Name) || profile.Name.Length > 100) throw new FormatException("名称需要 1–100 个字符。");
        profile = profile with { Config = WireGuardConfig.Validate(profile.Config) };
        var plain = JsonSerializer.SerializeToUtf8Bytes(profile);
        try { SecureStorage.WriteAtomic(PathFor(profile.Id), SecureStorage.Protect(plain, "TunnelOne profile")); }
        finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(plain); }
    }
    public void Delete(Guid id) => File.Delete(PathFor(id));
    private string PathFor(Guid id) => Path.Combine(DirectoryPath, id.ToString("N") + ".profile");

    public static IReadOnlyList<TunnelProfile> Import(string path)
    {
        var result = new List<TunnelProfile>();
        var utf8 = new UTF8Encoding(false, true);
        if (Path.GetExtension(path).Equals(".zip", StringComparison.OrdinalIgnoreCase))
        {
            using var zip = System.IO.Compression.ZipFile.OpenRead(path);
            var entries = zip.Entries.Where(e => e.Name.EndsWith(".conf", StringComparison.OrdinalIgnoreCase)).ToArray();
            if (entries.Length == 0 || entries.Length > 100) throw new FormatException("ZIP 需要包含 1–100 个 .conf 文件。");
            foreach (var entry in entries)
            {
                if (entry.Length > WireGuardConfig.MaxBytes) throw new FormatException("ZIP 中的配置超过 1 MiB。");
                using var stream = entry.Open();
                using var reader = new StreamReader(stream, utf8, false);
                var buffer = new char[WireGuardConfig.MaxBytes + 1];
                var length = reader.ReadBlock(buffer, 0, buffer.Length);
                if (length > WireGuardConfig.MaxBytes) throw new FormatException("ZIP 解压后的配置超过限制。");
                Add(entry.Name, new string(buffer, 0, length)); // Never extract untrusted entry paths.
            }
        }
        else
        {
            if (new FileInfo(path).Length > WireGuardConfig.MaxBytes) throw new FormatException("配置超过 1 MiB。");
            Add(Path.GetFileName(path), File.ReadAllText(path, utf8));
        }
        return result;
        void Add(string name, string config) => result.Add(new(Guid.NewGuid(), Path.GetFileNameWithoutExtension(name), WireGuardConfig.Validate(config.TrimStart('\uFEFF'))));
    }
}
