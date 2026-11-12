#!/usr/bin/env python3
from pathlib import Path
import json
import re

root = Path(__file__).resolve().parent.parent
version = (root / "VERSION").read_text().strip()
project = re.search(r'VERSION_NAME:\s*"([^"]+)"', (root / "project.yml").read_text())
assert project and project.group(1) == version, "project.yml version differs from VERSION"
assert json.loads((root / "package.json").read_text())["version"] == version, "Website package version mismatch"
assert (root / "docs/releases" / ("v" + version + ".md")).exists(), "Release notes missing"
print("Version inputs agree:", version)
