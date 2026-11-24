using System.IO.Compression;
using System.Text;
using TunnelOne.Core;

var privateKey = Convert.ToBase64String(Enumerable.Repeat((byte)7, 32).ToArray());
var publicKey = Convert.ToBase64String(Enumerable.Repeat((byte)9, 32).ToArray());
var config = $"[Interface]\nPrivateKey = {privateKey}\nAddress = 10.7.0.2/32, fd00::2/128\nDNS = 1.1.1.1\n\n[Peer]\nPublicKey = {publicKey}\nAllowedIPs = 10.7.0.0/24, fd00::/64\nEndpoint = example.com:51820\n";
int count = 0;
void Check(bool condition, string name) { if (!condition) throw new Exception("FAIL: " + name); Console.WriteLine("PASS: " + name); count++; }
void Reject(string text, string name) { try { WireGuardConfig.Validate(text); throw new Exception("Accepted invalid config: " + name); } catch (FormatException) { Check(true, name); } }
Check(WireGuardConfig.Validate(config).Contains("fd00::/64"), "IPv4 / IPv6 portable config");
Check(WireGuardConfig.Validate(config + $"\n[Peer]\nPublicKey = {publicKey}\nAllowedIPs = 192.168.0.0/16\n").Contains("192.168"), "multiple peers");
Reject(config.Replace("Address =", "PostUp = cmd.exe\nAddress ="), "reject elevated hooks");
Reject(config.Replace("PrivateKey = " + privateKey, "PrivateKey = bad"), "invalid key");
Reject(config.Replace("10.7.0.0/24", "10.7.0.0/99"), "invalid CIDR");
Reject(config.Replace("[Peer]", "[Interface]"), "duplicate interface");
Reject(config.Replace("PublicKey = " + publicKey, ""), "missing peer key");
Reject(config + "\nPrivateKey = secret", "reject keys in wrong section");
Reject(new string('x', WireGuardConfig.MaxBytes + 1), "size bound");
var temp = Path.Combine(Path.GetTempPath(), "TunnelOne-tests-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(temp);
try
{
    var store = new ProfileStore(Path.Combine(temp, "Profiles"));
    var profile = new TunnelProfile(Guid.NewGuid(), "测试隧道", config, false);
    store.Save(profile);
    Check(store.Load().Single() == profile, "DPAPI profile and preference roundtrip");
    var encrypted = File.ReadAllBytes(Directory.GetFiles(store.DirectoryPath).Single());
    Check(!Encoding.UTF8.GetString(encrypted).Contains(privateKey), "keys absent from profile ciphertext");
    var bytes = Encoding.UTF8.GetBytes(config);
    Check(SecureStorage.Unprotect(SecureStorage.Protect(bytes, "runtime", true)).SequenceEqual(bytes), "machine DPAPI runtime roundtrip");
    var zipPath = Path.Combine(temp, "profiles.zip");
    using (var zip = ZipFile.Open(zipPath, ZipArchiveMode.Create))
    using (var writer = new StreamWriter(zip.CreateEntry("../../escaped.conf").Open())) writer.Write(config);
    Check(ProfileStore.Import(zipPath).Single().Name == "escaped", "ZIP imports without path extraction");
    Check(!File.Exists(Path.Combine(temp, "escaped.conf")), "ZIP paths cannot escape");
    store.Delete(profile.Id);
    Check(store.Load().Count == 0, "profile deletion");
    store.Save(profile);
    File.WriteAllBytes(Directory.GetFiles(store.DirectoryPath).Single(), [1, 2, 3]);
    try { store.Load(); throw new Exception("Corrupt store accepted"); } catch (System.ComponentModel.Win32Exception) { Check(true, "corrupt encrypted store fails closed"); }
}
finally { Directory.Delete(temp, true); }
var tunnel = new TunnelProfile(Guid.NewGuid(), "Test", config);
var backend = new FakeBackend();
var proxy = new FakeProxy();
var session = new TunnelSession(backend, proxy);
await session.ConnectAsync(tunnel);
Check(backend.Running && proxy.Calls == 2 && session.Active == tunnel, "pre / post connection checks");
proxy.Version++;
await session.RefreshAsync();
Check(proxy.Calls == 3, "proxy changes revalidated");
await session.DisconnectAsync();
Check(!backend.Running && session.Active == null, "normal disconnect");
proxy.FailAt = proxy.Calls + 1;
try { await session.ConnectAsync(tunnel); } catch (IOException) { }
Check(!backend.Running && session.Active == null, "precheck failure starts no service");
proxy.FailAt = proxy.Calls + 2;
try { await session.ConnectAsync(tunnel); } catch (IOException) { }
Check(!backend.Running && session.Active == null && backend.Stops == 2, "postcheck failure rolls back");
proxy.FailAt = 0;
backend.FailStart = true;
try { await session.ConnectAsync(tunnel); } catch (IOException) { }
Check(!backend.Running && session.Active == null, "partial installation rolls back");
backend.FailStart = false;
await session.ConnectAsync(tunnel);
backend.FailStop = true;
try { await session.DisconnectAsync(); } catch (IOException) { }
Check(session.Active != null, "failed cleanup retains ownership for retry");
backend.FailStop = false;
await session.DisconnectAsync();
await session.ConnectAsync(tunnel);
proxy.Version++;
proxy.FailAt = proxy.Calls + 1;
try { await session.RefreshAsync(); } catch (IOException) { }
Check(session.Active == null && !backend.Running, "changed unavailable proxy disconnects owned tunnel");
proxy.FailAt = 0;
var calls = proxy.Calls;
await session.ConnectAsync(tunnel with { InheritProxy = false });
Check(proxy.Calls == calls, "disabled preference skips verification");
backend.Running = false;
try { await session.RefreshAsync(); } catch (IOException) { }
Check(session.Active == null, "stopped service resets session");
if (args.Contains("--integration"))
{
    var principal = new System.Security.Principal.WindowsPrincipal(System.Security.Principal.WindowsIdentity.GetCurrent());
    if (!principal.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator) || !WireGuardBackend.IsInstalled)
        throw new Exception("Integration tests require administrator rights and official WireGuard.");
    var real = new WireGuardBackend();
    // Only a documentation-only /32 route. No default route, DNS changes or public traffic.
    var isolated = new TunnelProfile(Guid.NewGuid(), "CI isolated interface",
        $"[Interface]\nPrivateKey = {privateKey}\nAddress = 192.0.2.2/32\n[Peer]\nPublicKey = {publicKey}\nAllowedIPs = 192.0.2.1/32\nEndpoint = 127.0.0.1:51820\n", false);
    try
    {
        await real.StartAsync(isolated);
        Check(await real.IsRunningAsync(isolated), "real encrypted WireGuard service starts");
        Check((await real.StatusAsync(isolated)).Contains("尚无握手"), "real wg statistics do not claim a handshake");
    }
    finally { await real.StopAsync(isolated); }
    Check(!await real.IsRunningAsync(isolated), "real service and adapter removed");
}
Console.WriteLine($"Windows tests passed: {count}");

sealed class FakeBackend : ITunnelBackend
{
    public bool Running, FailStart, FailStop;
    public int Stops;
    public Task StartAsync(TunnelProfile p) { Running = true; if (FailStart) throw new IOException("Partial install"); return Task.CompletedTask; }
    public Task StopAsync(TunnelProfile p) { if (FailStop) throw new IOException("Remove failed"); Running = false; Stops++; return Task.CompletedTask; }
    public Task<bool> IsRunningAsync(TunnelProfile p) => Task.FromResult(Running);
    public Task<string> StatusAsync(TunnelProfile p) => Task.FromResult("No handshake");
}
sealed class FakeProxy : IProxyGuard
{
    public int Calls, Version, FailAt;
    public string Fingerprint() => Version.ToString();
    public Task<string> VerifyAsync() { Calls++; if (Calls == FailAt) throw new IOException("Proxy unavailable"); return Task.FromResult("Verified"); }
}
