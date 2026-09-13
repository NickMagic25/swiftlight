#!/bin/sh
set -eu

# Xcode Cloud starts every action in a fresh environment. Prepare the native
# static dependencies from the pinned public Git sources before SwiftPM resolves
# and Xcode builds the local package. This deliberately avoids Git submodules:
# Cloud only needs access to the primary Swiftlight repository.
repo_root="${CI_PRIMARY_REPOSITORY_PATH:-${CI_WORKSPACE_PATH:-$(cd "$(dirname "$0")/.." && pwd)}}"
cd "$repo_root"
mkdir -p .build/ModuleCache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export GIT_TERMINAL_PROMPT=0
scripts/bootstrap-dependencies.sh
swift package --disable-sandbox --disable-dependency-cache --manifest-cache none --force-resolved-versions resolve
