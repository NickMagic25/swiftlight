#!/bin/sh
set -eu

# Xcode Cloud starts every action in a fresh environment. Prepare the native
# static dependencies before SwiftPM resolves and Xcode builds the local package.
repo_root="${CI_PRIMARY_REPOSITORY_PATH:-${CI_WORKSPACE_PATH:-$(cd "$(dirname "$0")/.." && pwd)}}"
cd "$repo_root"
mkdir -p .build/ModuleCache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export GIT_TERMINAL_PROMPT=0

# CMake is required to build Opus and is not preinstalled in Xcode Cloud.
if ! command -v cmake >/dev/null 2>&1; then
  brew install cmake
fi

scripts/bootstrap-dependencies.sh
swift package --disable-sandbox --disable-dependency-cache --manifest-cache none --force-resolved-versions resolve
