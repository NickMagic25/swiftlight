#!/bin/sh
set -eu

repo_root="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$repo_root"

# Each product has its own immutable release tags. Branch/TestFlight builds also
# need a fresh build number; retain their checked-in marketing version. Changes
# happen only in the disposable Cloud checkout, before Xcode processes the plist.
case "${CI_XCODE_SCHEME:-Swiftlight}" in
  SwiftlightMobile) version_prefix=ios; version_plist=App/Mobile-Info.plist ;;
  Swiftlight) version_prefix=macos; version_plist=App/Info.plist ;;
  *) echo "error: Unsupported Swiftlight Cloud scheme: $CI_XCODE_SCHEME" >&2; exit 1 ;;
esac
if [ -n "${CI_TAG:-}" ]; then
  case "$CI_TAG" in
    "$version_prefix"-v*) ;;
    *) echo "error: ${CI_XCODE_SCHEME:-Swiftlight} Cloud release tags must be named $version_prefix-vX.Y.Z" >&2; exit 1 ;;
  esac
  python3 scripts/release-version.py "${CI_TAG#*-}" --build-number "${CI_BUILD_NUMBER:?CI_BUILD_NUMBER is required}" --plist "$version_plist"
elif [ -n "${CI_BUILD_NUMBER:-}" ]; then
  python3 scripts/release-version.py --build-number "$CI_BUILD_NUMBER" --plist "$version_plist"
fi

# Configure this variable as "1" on the PR and release workflows in Xcode
# Cloud. A build action then retains the repository's existing complete SwiftPM
# and native validation gate before Xcode archives the app.
if [ "${SWIFTLIGHT_RUN_VALIDATION:-0}" = "1" ]; then
  # This gate builds and tests shared/native modules on the Cloud Mac. Its own
  # bootstrap prepares macOS dependencies in addition to the action's iOS ones.
  scripts/validate-ci.sh
fi
