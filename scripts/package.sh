#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(cat VERSION)"
kind="${1:-preview}"
app="build/DerivedData/Build/Products/Release/TunnelOne.app"
[[ -d "$app" ]] || { echo "Build TunnelOne first." >&2; exit 1; }
mkdir -p dist
stage="$(mktemp -d "$PWD/build/package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/TunnelOne.app"
cp LICENSE "$stage/LICENSE.txt"
cp ThirdParty/NOTICE.md "$stage/Third-Party-Notices.txt"
if [[ "$kind" == "preview" ]]; then
  cp docs/PREVIEW.txt "$stage/READ-ME-FIRST.txt"
else
  codesign --verify --deep --strict --verbose=2 "$stage/TunnelOne.app"
  xcrun stapler validate "$stage/TunnelOne.app"
fi
ln -s /Applications "$stage/Applications"
name="TunnelOne-${version}-macOS-universal-${kind}"
ditto -c -k --sequesterRsrc --keepParent "$stage/TunnelOne.app" "dist/${name}.zip"
hdiutil create -volname "TunnelOne ${version}" -srcfolder "$stage" \
  -ov -format UDZO "dist/${name}.dmg"
(
  cd dist
  shasum -a 256 "${name}.zip" "${name}.dmg" > "${name}.sha256"
)
