#!/bin/bash
# Package an already signed app. Release CI notarizes/staples the app before this step.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${RELEASE_TAG:?Set RELEASE_TAG to a stable SemVer tag such as v0.0.1}"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to a Developer ID Application identity}"
version="$(python3 scripts/release-version.py "$RELEASE_TAG")"
app_path="${APP_PATH:-$PWD/.build/Swiftlight.app}"
output_dir="${OUTPUT_DIR:-$PWD/artifacts/release}"
architecture="$(lipo -archs "$app_path/Contents/MacOS/Swiftlight")"
case "$architecture" in
  arm64|x86_64) ;;
  *) echo "ERROR: Expected one native architecture, got: $architecture" >&2; exit 1 ;;
esac
if [[ "$SIGNING_IDENTITY" == '-' ]]; then
  echo 'ERROR: Distribution DMGs require a real signing identity' >&2; exit 1
fi
actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
if [[ "$actual_version" != "$version" ]]; then
  echo "ERROR: App version $actual_version does not match release $version" >&2; exit 1
fi
codesign --verify --deep --strict --verbose=2 "$app_path"
mkdir -p "$output_dir"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/swiftlight-dmg.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ditto "$app_path" "$stage_dir/Swiftlight.app"
ln -s /Applications "$stage_dir/Applications"
printf 'Drag Swiftlight.app to Applications, then open Swiftlight from Applications.\nRequires macOS 14 or later.\n' > "$stage_dir/Install.txt"
dmg_path="$output_dir/Swiftlight-$version-macos-$architecture.dmg"
hdiutil create -volname "Swiftlight $version" -srcfolder "$stage_dir" -fs HFS+ -format UDZO -ov "$dmg_path"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$dmg_path"
codesign --verify --strict --verbose=2 "$dmg_path"
hdiutil verify "$dmg_path"
printf 'Built %s\n' "$dmg_path"
