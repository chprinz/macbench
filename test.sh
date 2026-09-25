#!/bin/bash
# Everything CI checks, on this Mac, fastest first. Run it before pushing.
#
#   ./test.sh          core tests, then the app build and the checks on it
#   ./test.sh --core   core tests only: no Xcode project, no xcodegen needed
set -euo pipefail
cd "$(dirname "$0")"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

step "Core tests"
(cd MacBenchCore && swift test)
[[ "${1:-}" == "--core" ]] && exit 0

step "App build"
./build.sh MacBench Release -quiet

step "Every string has a German version"
python3 tools/sync-strings.py build

step "The icon made it into the app"
xcrun assetutil --info build/Build/Products/Release/MacBench.app/Contents/Resources/Assets.car \
  | grep -q '"AppIcon"' || { echo "AppIcon is missing from the build"; exit 1; }

printf '\n\033[1;32m✓ Everything CI checks passed.\033[0m\n'
