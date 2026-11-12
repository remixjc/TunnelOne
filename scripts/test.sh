#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test
export PATH="$PWD/.tools/go/bin:$PATH"
export MIHOMO_BINARY="$PWD/build/core/mihomo"
pushd CoreLauncher >/dev/null
go test ./...
popd >/dev/null
python3 scripts/check_site.py
python3 scripts/check_version.py
python3 scripts/check_localizations.py
