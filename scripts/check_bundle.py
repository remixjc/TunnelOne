#!/usr/bin/env python3
"""Validate System Extension packaging; --signed additionally checks distribution assets."""
import argparse
import datetime
import pathlib
import plistlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=pathlib.Path)
parser.add_argument("--signed", action="store_true")
args = parser.parse_args()
app = args.app.resolve()


def plist(path):
    return plistlib.loads(path.read_bytes())


info = plist(app / "Contents/Info.plist")
identifier = info["CFBundleIdentifier"]
extension_id = identifier + ".network-extension"
extension = app / f"Contents/Library/SystemExtensions/{extension_id}.systemextension"
extension_info = plist(extension / "Contents/Info.plist")
assert not list(app.glob("Contents/PlugIns/*.appex")), "Legacy app extension must not be embedded"
assert extension_info["CFBundleIdentifier"] == extension_id
assert extension_info["CFBundlePackageType"] == "SYSX"
assert "NSExtension" not in extension_info
network = extension_info["NetworkExtension"]
assert network["NEProviderClasses"]["com.apple.networkextension.packet-tunnel"].endswith(".PacketTunnelProvider")
assert network["NEMachServiceName"] == info["TunnelOneMachServiceName"]
assert extension_info["CFBundleVersion"] == info["CFBundleVersion"]
assert float(info["LSMinimumSystemVersion"]) >= 13
for binary in (app / "Contents/MacOS/TunnelOne",
               extension / f"Contents/MacOS/{extension_id}",
               extension / "Contents/MacOS/mihomo",
               extension / "Contents/MacOS/tunnelone-core-launcher"):
    architectures = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
    assert set(architectures) == {"arm64", "x86_64"}, f"Not universal: {binary.name}"
    if args.signed:
        subprocess.run(["codesign", "--verify", "--strict", str(binary)], check=True)
        signature = subprocess.check_output(["codesign", "-dvv", str(binary)], stderr=subprocess.STDOUT, text=True)
        assert "Authority=Developer ID Application:" in signature, "Developer ID Application signature required"
        assert f"TeamIdentifier={info['TunnelOneTeamIdentifier']}" in signature
        assert "runtime" in signature, "Hardened runtime required"

if args.signed:
    team = info["TunnelOneTeamIdentifier"]
    assert network["NEMachServiceName"].startswith(team + ".group." + identifier + ".")
    for bundle, bundle_id in ((app, identifier), (extension, extension_id)):
        entitlements = plistlib.loads(subprocess.check_output(
            ["codesign", "-d", "--entitlements", ":-", str(bundle)], stderr=subprocess.DEVNULL))
        assert entitlements["com.apple.developer.networking.networkextension"] == ["packet-tunnel-provider-systemextension"]
        assert not entitlements.get("com.apple.security.get-task-allow", False)
        if bundle == app:
            assert entitlements.get("com.apple.developer.system-extension.install") is True
            assert entitlements.get("com.apple.security.network.client") is True, "Sandboxed WebKit needs network-client permission"
        else:
            assert not entitlements.get("com.apple.security.app-sandbox", False), "Service uses root-owned storage"
        profile = plistlib.loads(subprocess.check_output(
            ["security", "cms", "-D", "-i", str(bundle / "Contents/embedded.provisionprofile")]))
        assert team in profile["TeamIdentifier"]
        assert profile["ExpirationDate"] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
        assert "ProvisionsAllDevices" in profile and profile["ProvisionsAllDevices"]
        assert "Developer ID" in profile.get("Name", "") or profile.get("ProvisionsAllDevices")
        assert profile["Entitlements"]["com.apple.application-identifier"] == team + "." + bundle_id
        assert "packet-tunnel-provider-systemextension" in profile["Entitlements"]["com.apple.developer.networking.networkextension"]
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print("System Extension bundle validation passed" + (" (Developer ID)." if args.signed else " (unsigned preview)."))
