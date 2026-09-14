#!/bin/sh
# Run from an Xcode Resources build phase, before the app is code-signed.
set -eu

if [ "$#" -ne 1 ]; then
  echo 'usage: scripts/copy-app-licenses.sh <bundle-resource-licenses-directory>' >&2
  exit 2
fi
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
destination="$1"
decoder_root="${SWIFTLIGHT_DECODER_PATH:-$repo_root/.build/checkouts/moonlight-apple-decoder}"
if [ ! -f "$decoder_root/LICENSE" ] && [ -n "${BUILD_DIR:-}" ] && [ -z "${SWIFTLIGHT_DECODER_PATH:-}" ]; then
  decoder_root="$BUILD_DIR/../../SourcePackages/checkouts/moonlight-apple-decoder"
fi

# All platform builds use the same verified upstream license texts. Bootstrap
# collects Opus/OpenSSL notices here even when their static libraries are built
# for iOS. Fail on missing inputs rather than shipping an incomplete bundle.
# SwiftPM checkout files may be read-only. Install normalizes output permissions
# so repeated Xcode builds can replace notices without changing source modes.
mkdir -p "$destination"
install -m 644 "$repo_root/LICENSE" "$destination/Swiftlight.txt"
install -m 644 "$repo_root/.build/dependencies/licenses/OpenSSL.txt" "$destination/OpenSSL.txt"
install -m 644 "$repo_root/.build/dependencies/licenses/Opus.txt" "$destination/Opus.txt"
install -m 644 "$decoder_root/LICENSE" "$destination/MoonlightAppleVideo.txt"
install -m 644 "$repo_root/Sources/CStreamBridge/vendor/common-c/LICENSE.txt" "$destination/moonlight-common-c.txt"
install -m 644 "$repo_root/Sources/CStreamBridge/vendor/common-c/enet/LICENSE" "$destination/enet.txt"
install -m 644 "$repo_root/Sources/CStreamBridge/vendor/common-c/nanors/LICENSE" "$destination/nanors.txt"
