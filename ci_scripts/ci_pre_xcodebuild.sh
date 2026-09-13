#!/bin/sh
set -eu

# Version a protected macOS direct-distribution archive from its immutable tag.
# Xcode Cloud runs in a disposable checkout, so this never changes the source
# plist in the repository. `release-version.py` rejects non-stable SemVer.
if [ -n "${CI_TAG:-}" ]; then
  case "$CI_TAG" in
    macos-v*) ;;
    *) echo "error: Swiftlight Cloud release tags must be named macos-vX.Y.Z" >&2; exit 1 ;;
  esac
  repo_root="${CI_PRIMARY_REPOSITORY_PATH:-${CI_WORKSPACE_PATH:-$(cd "$(dirname "$0")/.." && pwd)}}"
  cd "$repo_root"
  python3 scripts/release-version.py "${CI_TAG#macos-}" --build-number "${CI_BUILD_NUMBER:?CI_BUILD_NUMBER is required}" --plist App/Info.plist
fi

# Configure this variable as "1" on the PR and release workflows in Xcode
# Cloud. A build action then retains the repository's existing complete SwiftPM
# and native validation gate before Xcode archives the app.
if [ "${SWIFTLIGHT_RUN_VALIDATION:-0}" = "1" ]; then
  repo_root="${CI_PRIMARY_REPOSITORY_PATH:-${CI_WORKSPACE_PATH:-$(cd "$(dirname "$0")/.." && pwd)}}"
  cd "$repo_root"
  scripts/validate-ci.sh
fi
