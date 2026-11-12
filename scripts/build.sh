#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/prepare.py
export PATH="$PWD/.tools/go/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=12.0
make -C Sources/WireGuardKitGo \
  CONFIGURATION_BUILD_DIR="$PWD/build/bridge" \
  CONFIGURATION_TEMP_DIR="$PWD/build/bridge/temp" \
  DEPLOYMENT_TARGET_CLANG_FLAG_NAME=mmacosx-version-min \
  DEPLOYMENT_TARGET_CLANG_ENV_NAME=MACOSX_DEPLOYMENT_TARGET \
  ARCHS="arm64 x86_64" build version-header
xcodegen generate
signing=(CODE_SIGNING_ALLOWED=NO)
if [[ "${1:-}" == "--signed" ]]; then
  signing=(CODE_SIGNING_ALLOWED=YES)
fi
xcodebuild -project TunnelOne.xcodeproj -scheme TunnelOne -configuration Release \
  -derivedDataPath build/DerivedData -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  "${signing[@]}" build
