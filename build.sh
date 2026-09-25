#!/bin/bash
# Regenerates the Xcode project from project.yml, then builds the app. The
# project file is derived, not edited.
#
#   ./build.sh                     MacBench, Debug
#   ./build.sh MacBench Release
#   ./build.sh <Target> [Config]   a build of your own, from project.local.yml
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }
# project.local.yml, where it exists, includes project.yml and adds targets of
# your own. It is never committed; see docs/development.md.
spec=project.yml
[[ -f project.local.yml ]] && spec=project.local.yml
xcodegen generate --spec "$spec" --quiet
# The build number is the commit count, so two builds of the same version can be
# told apart - which is the only moment a build number is ever wanted.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
xcodebuild -project MacBench.xcodeproj -scheme "${1:-MacBench}" -configuration "${2:-Debug}" \
  -derivedDataPath "${DERIVED_DATA:-build}" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build "${@:3}"
