#!/usr/bin/env python3
"""Ensure static native translation lookups resolve in the fallback table."""
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
table = root / "Sources/WireGuardApp/Base.lproj/Localizable.strings"
keys = set(re.findall(r'^"([^"]+)"\s*=', table.read_text(), re.MULTILINE))
missing = set()
for path in (root / "Sources").rglob("*.swift"):
    for key in re.findall(r'tr\(\s*(?:format:\s*)?"([^"]+)"', path.read_text()):
        if key not in keys:
            missing.add(key)
assert not missing, "Missing fallback translations: " + ", ".join(sorted(missing))
for language in (root / "Sources/WireGuardApp").glob("*.lproj/Localizable.strings"):
    localized = set(re.findall(r'^"([^"]+)"\s*=', language.read_text(), re.MULTILINE))
    assert "macConfirmAndQuitAlertQuitWireGuard" in localized, f"Missing quit key in {language.parent.name}"
print("Native localization keys checked.")
