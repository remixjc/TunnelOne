#!/usr/bin/env python3
"""Validate and import Apple signing assets on an ephemeral GitHub-hosted runner."""
import base64
import datetime
import os
from pathlib import Path
import plistlib
import re
import secrets
import subprocess
import urllib.request

if os.environ.get('GITHUB_ACTIONS') != 'true':
    raise SystemExit('Run this script only on an ephemeral GitHub Actions runner.')
kind = os.environ.get('SIGNING_KIND', 'developer-id')
if kind not in ('developer-id', 'development'):
    raise SystemExit('Invalid SIGNING_KIND')
certificate_value = os.environ.get('MAC_CSC_LINK') or os.environ.get('CERTIFICATE_P12')
certificate_password = os.environ.get('MAC_CSC_KEY_PASSWORD') or os.environ.get('CERTIFICATE_PASSWORD')
required = ['APP_PROFILE', 'EXTENSION_PROFILE', 'APPLE_TEAM_ID', 'RUNNER_TEMP']
missing = [name for name in required if not os.environ.get(name)]
if not certificate_value: missing.append('MAC_CSC_LINK / CERTIFICATE_P12')
if not certificate_password: missing.append('MAC_CSC_KEY_PASSWORD / CERTIFICATE_PASSWORD')
if missing: raise SystemExit('Missing signing secrets: ' + ', '.join(missing))
team = os.environ['APPLE_TEAM_ID']
assert re.fullmatch(r'[A-Z0-9]{10}', team), 'Invalid Team ID'
app_id = 'io.github.remixjc.TunnelOne'
capability = 'packet-tunnel-provider-systemextension' if kind == 'developer-id' else 'packet-tunnel-provider'
identity_name = 'Developer ID Application' if kind == 'developer-id' else 'Apple Development'
temporary = Path(os.environ['RUNNER_TEMP'])
keychain = temporary / 'TunnelOne-signing.keychain-db'
password = secrets.token_hex(24)
print('::add-mask::' + password)
certificate = temporary / 'TunnelOne-signing.p12'

def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

try:
    if certificate_value.startswith('https://'):
        # electron-builder also accepts an HTTPS p12 URL. Never print that URL.
        with urllib.request.urlopen(certificate_value, timeout=30) as response:
            raw = response.read(4 * 1024 * 1024 + 1)
        assert len(raw) <= 4 * 1024 * 1024
    else:
        if certificate_value.startswith('data:'): certificate_value = certificate_value.split(',', 1)[1]
        raw = base64.b64decode(''.join(certificate_value.split()), validate=True)
    certificate.write_bytes(raw)
    certificate.chmod(0o600)
    run('security', 'create-keychain', '-p', password, str(keychain))
    run('security', 'set-keychain-settings', '-lut', '21600', str(keychain))
    run('security', 'unlock-keychain', '-p', password, str(keychain))
    run('security', 'import', str(certificate), '-k', str(keychain), '-P', certificate_password,
        '-T', '/usr/bin/codesign')
    run('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, str(keychain))
    run('security', 'list-keychains', '-d', 'user', '-s', str(keychain))
except Exception:
    raise SystemExit('Could not import signing certificate; check its encoding, URL, password and private key.') from None
finally:
    certificate.unlink(missing_ok=True)
identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning', str(keychain)], text=True)
matches = re.findall(r'([A-F0-9]{40}) "' + re.escape(identity_name) + r': [^"\n]+ \(' + team + r'\)"', identities)
assert len(matches) == 1, 'Exactly one valid signing identity for the selected team and signing kind is required'
identity = matches[0]
profiles = Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles'
profiles.mkdir(parents=True, exist_ok=True)
identifiers = {}
installed = []
for variable, bundle_id in [('APP_PROFILE', app_id), ('EXTENSION_PROFILE', app_id + '.network-extension')]:
    try:
        raw = base64.b64decode(''.join(os.environ[variable].split()), validate=True)
        path = temporary / (variable + '.provisionprofile')
        path.write_bytes(raw)
        path.chmod(0o600)
        profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(path)], stderr=subprocess.DEVNULL))
        path.unlink()
        entitlements = profile['Entitlements']
        assert team in profile['TeamIdentifier'], 'Profile Team mismatch'
        assert entitlements['com.apple.application-identifier'] == team + '.' + bundle_id, 'Profile Bundle ID mismatch'
        assert capability in entitlements.get('com.apple.developer.networking.networkextension', []), 'Wrong Network Extension entitlement'
        assert profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Profile expired'
        if kind == 'developer-id':
            assert profile.get('ProvisionsAllDevices') and not entitlements.get('get-task-allow'), 'Developer ID distribution profile required'
        uuid = profile['UUID']
        assert re.fullmatch(r'[A-Fa-f0-9-]{36}', uuid), 'Invalid profile UUID'
    except Exception:
        raise SystemExit(f'{variable} is not a valid {kind} profile for {bundle_id} and the selected team.') from None
    destination = profiles / (uuid + '.provisionprofile')
    destination.write_bytes(raw)
    installed.append(str(destination))
    (temporary / 'TunnelOne-installed-profiles.txt').write_text('\n'.join(installed))
    identifiers[variable] = uuid
(temporary / 'TunnelOne-installed-profiles.txt').write_text('\n'.join(installed))
Path('Config/Signing.xcconfig').write_text(
    f'DEVELOPMENT_TEAM = {team}\nCODE_SIGN_STYLE = Manual\nCODE_SIGN_IDENTITY = {identity}\n'
    f'NETWORK_EXTENSION_KIND = {capability}\n'
    f"APP_PROFILE = {identifiers['APP_PROFILE']}\nEXTENSION_PROFILE = {identifiers['EXTENSION_PROFILE']}\n")
with open(os.environ['GITHUB_ENV'], 'a') as environment:
    environment.write(f'TUNNELONE_SIGNING_IDENTITY={identity}\nTUNNELONE_SIGNING_KEYCHAIN={keychain}\n')
print(f'Validated {kind} profiles and imported signing assets; private values were not printed.')
