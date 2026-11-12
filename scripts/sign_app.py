#!/usr/bin/env python3
"""Sign the compiled app explicitly, including Xcode-managed Developer ID profiles.

Xcode rejects its managed profiles in a manual-signing build. Compiling without
signing and applying codesign explicitly also avoids its NE entitlement export bug.
"""
import hashlib
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
settings = {}
for line in (ROOT / "Config/Signing.xcconfig").read_text().splitlines():
    if "=" in line and not line.lstrip().startswith("//"):
        key, value = line.split("=", 1)
        settings[key.strip()] = value.strip()
team = settings["DEVELOPMENT_TEAM"]
identity = settings["CODE_SIGN_IDENTITY"]
assert re.fullmatch(r"[A-Z0-9]{10}", team), "Invalid Team ID"
assert re.fullmatch(r"[A-Fa-f0-9]{40}", identity), "Use the selected signing identity's SHA-1 fingerprint"
kind = settings.get("NETWORK_EXTENSION_KIND", "packet-tunnel-provider-systemextension")
assert kind in ("packet-tunnel-provider-systemextension", "packet-tunnel-provider")
app = ROOT / "build/DerivedData/Build/Products/Release/TunnelOne.app"
app_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
app_id = app_info["CFBundleIdentifier"]
assert app_info["TunnelOneTeamIdentifier"] == team, "Rebuild with the selected Team ID"
extension = app / f"Contents/Library/SystemExtensions/{app_id}.network-extension.systemextension"
profile_dir = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
for bundle, setting in ((app, "APP_PROFILE"), (extension, "EXTENSION_PROFILE")):
    uuid = settings[setting]
    assert re.fullmatch(r"[A-Fa-f0-9-]{36}", uuid), "Use a provisioning profile UUID"
    profile_path = profile_dir / (uuid + ".provisionprofile")
    profile = plistlib.loads(subprocess.check_output(
        ["security", "cms", "-D", "-i", str(profile_path)], stderr=subprocess.DEVNULL))
    bundle_id = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
    assert team in profile["TeamIdentifier"]
    assert profile["Entitlements"]["com.apple.application-identifier"] == team + "." + bundle_id
    assert kind in profile["Entitlements"]["com.apple.developer.networking.networkextension"]
    assert identity.upper() in {hashlib.sha1(value).hexdigest().upper() for value in profile["DeveloperCertificates"]}, \
        "Provisioning profile does not authorize the imported signing certificate"
    shutil.copyfile(profile_path, bundle / "Contents/embedded.provisionprofile")


def sign(path, entitlement_source=None):
    command = ["codesign", "--force", "--options", "runtime", "--timestamp", "--sign", identity]
    with tempfile.TemporaryDirectory(prefix="TunnelOne-entitlements-") as directory:
        if entitlement_source:
            source = (ROOT / entitlement_source).read_text()
            for key, value in {"DEVELOPMENT_TEAM": team, "APP_ID_MACOS": app_id,
                               "NETWORK_EXTENSION_KIND": kind}.items():
                source = source.replace("$(" + key + ")", value)
            assert "$(" not in source, "Unexpanded signing entitlement"
            values = plistlib.loads(source.encode())
            bundle_id = plistlib.loads((path / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
            values["com.apple.application-identifier"] = team + "." + bundle_id
            values["com.apple.developer.team-identifier"] = team
            entitlements = Path(directory) / "entitlements.plist"
            entitlements.write_bytes(plistlib.dumps(values))
            command += ["--entitlements", str(entitlements), "--generate-entitlement-der"]
        subprocess.run(command + [str(path)], check=True)


for binary in ("mihomo", "tunnelone-core-launcher"):
    sign(extension / "Contents/MacOS" / binary)
sign(app / "Contents/Library/LoginItems/TunnelOneLoginItemHelper.app",
     "Sources/WireGuardApp/UI/macOS/LoginItemHelper/LoginItemHelper.entitlements")
sign(extension, "Sources/WireGuardNetworkExtension/WireGuardNetworkExtension_macOS.entitlements")
sign(app, "Sources/WireGuardApp/UI/macOS/WireGuard.entitlements")
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print("Explicit inside-out signing completed; embedded profiles match the selected certificate.")
