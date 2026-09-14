#!/bin/sh
set -eu

# Xcode Cloud starts every action in a fresh environment. Prepare the native
# static dependencies before SwiftPM resolves and Xcode builds the local package.
repo_root="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$repo_root"
mkdir -p .build/ModuleCache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export GIT_TERMINAL_PROMPT=0

# CMake is required to build Opus and is not preinstalled in Xcode Cloud.
if ! command -v cmake >/dev/null 2>&1; then
  brew install cmake
fi

# Build actions may target either Any iOS Device or Any iOS Simulator; Cloud
# does not publish a destination SDK variable. Prepare both for those actions.
# Archives only need the device slice. iPhone and iPad share the iOS SDK.
case "${CI_XCODE_SCHEME:-Swiftlight}" in
  SwiftlightMobile)
    scripts/bootstrap-dependencies.sh --platform ios
    if [ "${CI_XCODEBUILD_ACTION:-build}" != "archive" ]; then
      scripts/bootstrap-dependencies.sh --platform ios-simulator
    fi
    ;;
  Swiftlight) scripts/bootstrap-dependencies.sh --platform macos ;;
  *) echo "error: Unsupported Swiftlight Cloud scheme: $CI_XCODE_SCHEME" >&2; exit 1 ;;
esac
swift package --disable-sandbox --disable-dependency-cache --manifest-cache none --force-resolved-versions resolve
