#!/bin/sh
set -eu

repo_root="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$repo_root"

# Both platforms use the same immutable release tags. Branch/TestFlight builds
# need a fresh build number; retain their checked-in marketing version. Changes
# happen only in the disposable Cloud checkout, before Xcode processes the plist.
if [ "${CI_XCODE_SCHEME:-}" != "Swiftlight" ]; then
  echo "error: Expected the Swiftlight Cloud scheme" >&2
  exit 1
fi
case "${CI_PRODUCT_PLATFORM:-}" in
  iOS) version_plist=App/Mobile-Info.plist ;;
  macOS) version_plist=App/Info.plist ;;
  *) echo "error: Unsupported or missing Cloud action platform: ${CI_PRODUCT_PLATFORM:-unset}" >&2; exit 1 ;;
esac
set --
if [ -n "${CI_COMMIT:-}" ]; then
  set -- --commit-sha "$CI_COMMIT"
fi
if [ -n "${CI_TAG:-}" ]; then
  python3 scripts/release-version.py "$CI_TAG" --build-number "${CI_BUILD_NUMBER:?CI_BUILD_NUMBER is required}" --plist "$version_plist" "$@"
elif [ -n "${CI_BUILD_NUMBER:-}" ]; then
  python3 scripts/release-version.py --build-number "$CI_BUILD_NUMBER" --plist "$version_plist" "$@"
fi

# Configure this variable as "1" on the PR and release workflows in Xcode
# Cloud. A build action then retains the repository's existing complete SwiftPM
# and native validation gate before Xcode archives the app.
if [ "${SWIFTLIGHT_RUN_VALIDATION:-0}" = "1" ]; then
  # This gate builds and tests shared/native modules on the Cloud Mac. Its own
  # bootstrap prepares macOS dependencies in addition to the action's iOS ones.
  scripts/validate-ci.sh
fi
