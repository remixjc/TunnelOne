#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${APPLE_ID:?Missing Apple ID}"
: "${APPLE_APP_SPECIFIC_PASSWORD:?Missing app-specific password}"
: "${APPLE_TEAM_ID:?Missing Team ID}"
: "${TUNNELONE_SIGNING_KEYCHAIN:?Missing temporary signing keychain}"
: "${TUNNELONE_SIGNING_IDENTITY:?Missing signing identity}"
mode="${1:-app}"
profile="TunnelOne-notarization"
if [[ "$mode" == app ]]; then
  python3 scripts/check_bundle.py build/DerivedData/Build/Products/Release/TunnelOne.app --signed
  xcrun notarytool store-credentials "$profile" --keychain "$TUNNELONE_SIGNING_KEYCHAIN" \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" >/dev/null
  target="build/DerivedData/Build/Products/Release/TunnelOne.app"
  upload="$RUNNER_TEMP/TunnelOne-notarization.zip"
  ditto -c -k --sequesterRsrc --keepParent "$target" "$upload"
elif [[ "$mode" == dmg ]]; then
  target="dist/TunnelOne-$(cat VERSION)-macOS-universal-signed.dmg"
  codesign --force --timestamp --sign "$TUNNELONE_SIGNING_IDENTITY" "$target"
  upload="$target"
else
  echo 'Expected app or dmg.' >&2
  exit 1
fi
result="$RUNNER_TEMP/TunnelOne-notary-${mode}.json"
xcrun notarytool submit "$upload" --keychain-profile "$profile" --keychain "$TUNNELONE_SIGNING_KEYCHAIN" \
  --wait --timeout 30m --output-format json > "$result"
python3 - "$result" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
print('Apple notarization status:', result.get('status', 'Unknown'))
if result.get('status') != 'Accepted':
    print('Submission ID:',result.get('id','Unknown'))
    raise SystemExit('Notarization was not accepted; publication has been stopped.')
PY
xcrun stapler staple "$target"
xcrun stapler validate "$target"
if [[ "$mode" == app ]]; then
  spctl --assess --type execute --verbose=2 "$target"
else
  spctl --assess --type open --context context:primary-signature --verbose=2 "$target"
fi
