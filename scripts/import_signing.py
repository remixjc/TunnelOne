#!/usr/bin/env python3
"""Import signing secrets on an ephemeral GitHub-hosted runner only."""
import base64
import os
from pathlib import Path
import plistlib
import secrets
import subprocess

required = ["CERTIFICATE_P12", "CERTIFICATE_PASSWORD", "APP_PROFILE",
            "EXTENSION_PROFILE", "APPLE_TEAM_ID", "RUNNER_TEMP"]
missing = [key for key in required if not os.environ.get(key)]
if missing:
    raise SystemExit("Missing signing secrets: " + ", ".join(missing))
if os.environ.get("GITHUB_ACTIONS") != "true":
    raise SystemExit("Run this script only on an ephemeral GitHub Actions runner.")
temporary = Path(os.environ["RUNNER_TEMP"])
keychain = temporary / "TunnelOne-signing.keychain-db"
password = secrets.token_hex(24)
print("::add-mask::" + password)
certificate = temporary / "TunnelOne-signing.p12"
certificate.write_bytes(base64.b64decode(os.environ["CERTIFICATE_P12"], validate=True))
certificate.chmod(0o600)


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL)


run("security", "create-keychain", "-p", password, str(keychain))
run("security", "set-keychain-settings", "-lut", "21600", str(keychain))
run("security", "unlock-keychain", "-p", password, str(keychain))
run("security", "import", str(certificate), "-k", str(keychain), "-P",
    os.environ["CERTIFICATE_PASSWORD"], "-T", "/usr/bin/codesign")
certificate.unlink()
run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
    "-s", "-k", password, str(keychain))
run("security", "list-keychains", "-d", "user", "-s", str(keychain))
profiles = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
profiles.mkdir(parents=True, exist_ok=True)
identifiers = {}
for variable in ("APP_PROFILE", "EXTENSION_PROFILE"):
    raw = base64.b64decode(os.environ[variable], validate=True)
    path = temporary / (variable + ".provisionprofile")
    path.write_bytes(raw)
    decoded = subprocess.check_output(["security", "cms", "-D", "-i", str(path)])
    profile = plistlib.loads(decoded)
    entitlements = profile["Entitlements"]
    assert os.environ["APPLE_TEAM_ID"] in profile["TeamIdentifier"], "Profile Team mismatch"
    assert "packet-tunnel-provider" in entitlements.get(
        "com.apple.developer.networking.networkextension", []), "Network Extension entitlement missing"
    uuid = profile["UUID"]
    assert all(character.isalnum() or character == "-" for character in uuid)
    (profiles / (uuid + ".provisionprofile")).write_bytes(raw)
    identifiers[variable] = uuid
team = os.environ["APPLE_TEAM_ID"]
assert team.isalnum(), "Invalid Team ID"
Path("Config/Signing.xcconfig").write_text(
    f"DEVELOPMENT_TEAM = {team}\nCODE_SIGN_STYLE = Manual\n"
    "CODE_SIGN_IDENTITY = Apple Development\n"
    f"APP_PROFILE = {identifiers['APP_PROFILE']}\n"
    f"EXTENSION_PROFILE = {identifiers['EXTENSION_PROFILE']}\n"
)
print("Signing assets imported; private values were not printed.")
