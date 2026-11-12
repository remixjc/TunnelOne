#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
probe_root="$PWD/build/native-ui-smoke"
probe_app="$probe_root/NativeUISmoke.app"
mkdir -p "$probe_app/Contents/MacOS" "$probe_app/Contents/Resources"
cp -R Sources/WireGuardApp/Resources/TunnelOneUI "$probe_app/Contents/Resources/"
python3 - "$probe_root" <<'PY'
from pathlib import Path
import plistlib
import sys

root = Path(sys.argv[1])
info = {
    "CFBundleIdentifier": "io.github.remixjc.TunnelOne.NativeUISmoke",
    "CFBundleExecutable": "NativeUISmoke",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": Path("VERSION").read_text().strip(),
    "LSUIElement": True,
}
(root / "NativeUISmoke.app/Contents/Info.plist").write_bytes(plistlib.dumps(info))
# Keep the production sandbox/WebKit permissions. Team/profile-bound VPN and
# App Group entitlements are irrelevant to this isolated ad-hoc UI process.
production = plistlib.loads(Path("Sources/WireGuardApp/UI/macOS/WireGuard.entitlements").read_bytes())
keys = ["com.apple.security.app-sandbox", "com.apple.security.network.client",
        "com.apple.security.files.user-selected.read-write"]
(root / "smoke.entitlements").write_bytes(plistlib.dumps({k: production[k] for k in keys if k in production}))
PY
swiftc Sources/WireGuardApp/UI/macOS/View/TunnelOneWebView.swift Tests/ClientUISmoke/main.swift \
  -framework Cocoa -framework WebKit -o "$probe_app/Contents/MacOS/NativeUISmoke"
codesign --force --sign - --entitlements "$probe_root/smoke.entitlements" "$probe_app"
if ! "$probe_app/Contents/MacOS/NativeUISmoke" > "$probe_root/result.log" 2>&1; then
  cat "$probe_root/result.log" >&2
  exit 1
fi
cat "$probe_root/result.log"
python3 - "$probe_root" <<'PY'
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1])
snapshot = next(line.removeprefix("Snapshot: ") for line in (root / "result.log").read_text().splitlines()
                if line.startswith("Snapshot: "))
shutil.copyfile(snapshot, root / "native-ui-smoke.png")
PY
