#!/bin/sh
set -eu

# Xcode Cloud starts every action in a fresh environment. Prepare the native
# static dependencies before SwiftPM resolves and Xcode builds the local package.
repo_root="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$repo_root"
mkdir -p .build/ModuleCache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export GIT_TERMINAL_PROMPT=0

# One scheme supports every destination. Cloud identifies the current action's
# platform independently of the scheme; do not infer it from a product name.
if [ "${CI_XCODE_SCHEME:-}" != "Swiftlight" ]; then
  echo "error: Expected the Swiftlight Cloud scheme" >&2
  exit 1
fi
case "${CI_PRODUCT_PLATFORM:-}" in
  iOS|macOS) ;;
  *) echo "error: Unsupported or missing Cloud action platform: ${CI_PRODUCT_PLATFORM:-unset}" >&2; exit 1 ;;
esac

# CMake is required to build Opus and is not preinstalled in Xcode Cloud.
if ! command -v cmake >/dev/null 2>&1; then
  brew install cmake
fi

# Build actions may target either Any iOS Device or Any iOS Simulator; Cloud
# does not publish a destination SDK variable. Prepare both for those actions.
# Archives only need the device slice. iPhone and iPad share the iOS SDK.
case "$CI_PRODUCT_PLATFORM" in
  iOS)
    scripts/bootstrap-dependencies.sh --platform ios
    if [ "${CI_XCODEBUILD_ACTION:-build}" != "archive" ]; then
      scripts/bootstrap-dependencies.sh --platform ios-simulator
    fi
    ;;
  macOS) scripts/bootstrap-dependencies.sh --platform macos ;;
esac
swift package --disable-sandbox --disable-dependency-cache --manifest-cache none --force-resolved-versions resolve
