#!/usr/bin/env python3
"""Remove temporary runner signing material, including imported profiles."""
import os
from pathlib import Path
import subprocess

if os.environ.get('GITHUB_ACTIONS') != 'true':
    raise SystemExit('Runner only')
temporary = Path(os.environ['RUNNER_TEMP'])
subprocess.run(['security', 'delete-keychain', str(temporary / 'TunnelOne-signing.keychain-db')],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
record = temporary / 'TunnelOne-installed-profiles.txt'
if record.exists():
    parent = Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles'
    for line in record.read_text().splitlines():
        path = Path(line)
        if path.parent == parent and path.suffix == '.provisionprofile': path.unlink(missing_ok=True)
    record.unlink()
Path('Config/Signing.xcconfig').unlink(missing_ok=True)
for name in ('APP_PROFILE.provisionprofile', 'EXTENSION_PROFILE.provisionprofile', 'TunnelOne-signing.p12'):
    (temporary / name).unlink(missing_ok=True)
