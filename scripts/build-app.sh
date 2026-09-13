#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-debug}"
case "$configuration" in
  debug|release) ;;
  *) echo 'ERROR: CONFIGURATION must be debug or release' >&2; exit 1 ;;
esac

if [[ "${SIGNING_IDENTITY+x}" == x ]]; then
  signing_identity="$SIGNING_IDENTITY"
  if [[ -z "${signing_identity//[[:space:]]/}" ]]; then
    echo 'ERROR: SIGNING_IDENTITY is empty; use a certificate name/hash or - for an ad-hoc debug build' >&2
    exit 1
  fi
elif [[ "$configuration" == release ]]; then
  echo 'ERROR: Release builds require an explicit real SIGNING_IDENTITY; automatic or ad-hoc signing is only for debug builds' >&2
  exit 1
else
  if ! available_identities="$(security find-identity -v -p codesigning 2>&1)"; then
    echo 'ERROR: Cannot inspect code-signing identities. Set SIGNING_IDENTITY explicitly or check security find-identity -v -p codesigning' >&2
    exit 1
  fi
  signing_identities=()
  while IFS= read -r identity; do
    [[ -n "$identity" ]] && signing_identities+=("$identity")
  done < <(printf '%s\n' "$available_identities" | sed -En \
    's/^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"(Apple Development|Developer ID Application):[^"]+"[[:space:]]*$/\1/p' | sort -u)
  case "${#signing_identities[@]}" in
    0) signing_identity='-' ;;
    1) signing_identity="${signing_identities[0]}"
       printf 'Using the sole available Apple Development/Developer ID Application identity: %s\n' "$signing_identity" ;;
    *) echo 'ERROR: Multiple Apple Development/Developer ID Application identities are available; set SIGNING_IDENTITY explicitly' >&2
       exit 1 ;;
  esac
fi
if [[ "$signing_identity" == '-' ]]; then
  if [[ "$configuration" == release ]]; then
    echo 'ERROR: Release builds require a real SIGNING_IDENTITY; ad-hoc signing is not allowed' >&2
    exit 1
  fi
  echo 'NOTICE: This debug build uses ad-hoc signing. Rebuilding can trigger macOS Keychain authorization again; use a stable SIGNING_IDENTITY to retain the app signing identity across builds.' >&2
fi

export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
scripts/bootstrap-dependencies.sh
swift build --disable-sandbox --manifest-cache none -c "$configuration" --product Swiftlight
bin_path="$(swift build --disable-sandbox --manifest-cache none -c "$configuration" --show-bin-path)"
app_path="$PWD/.build/Swiftlight.app"
stage_dir="$(mktemp -d "$PWD/.build/.Swiftlight-stage.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
staged_app="$stage_dir/Swiftlight.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources/Licenses"
cp -f "$bin_path/Swiftlight" "$staged_app/Contents/MacOS/Swiftlight"
cp -f App/Info.plist "$staged_app/Contents/Info.plist"
cp -f LICENSE "$staged_app/Contents/Resources/Licenses/Swiftlight.txt"
cp -f .build/dependencies/licenses/*.txt "$staged_app/Contents/Resources/Licenses/"
cp -f Sources/CStreamBridge/vendor/common-c/LICENSE.txt "$staged_app/Contents/Resources/Licenses/moonlight-common-c.txt"
decoder_path="${SWIFTLIGHT_DECODER_PATH:-.build/checkouts/moonlight-apple-decoder}"
cp -f "$decoder_path/LICENSE" "$staged_app/Contents/Resources/Licenses/MoonlightAppleVideo.txt"
for entry in Sources/CStreamBridge/vendor/common-c/enet/LICENSE Sources/CStreamBridge/vendor/common-c/nanors/LICENSE; do
  if [[ -f "$entry" ]]; then cp -f "$entry" "$staged_app/Contents/Resources/Licenses/$(basename "$(dirname "$entry")").txt"; fi
done
codesign --force --sign "$signing_identity" "$staged_app"
codesign --verify --deep --strict --verbose=2 "$staged_app"
plutil -lint "$staged_app/Contents/Info.plist"
path_check="$(otool -L "$staged_app/Contents/MacOS/Swiftlight")"
if [[ "$path_check" == *'/opt/homebrew/'* ]]; then
  echo 'ERROR: application has a Homebrew dynamic-library dependency' >&2; exit 1
fi
# Exchange the complete directories atomically on the same volume. A failed swap
# leaves the old bundle intact; its executable is never opened for writing.
python3 - "$staged_app" "$app_path" <<'PY'
import ctypes
import os
import sys

staged, destination = sys.argv[1:]
if os.path.lexists(destination):
    if os.path.islink(destination) or not os.path.isdir(destination):
        raise SystemExit("ERROR: Existing app path must be a real directory; left unchanged")
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    renamex = libc.renamex_np
    renamex.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    renamex.restype = ctypes.c_int
    # RENAME_SWAP from the public macOS sys/stdio.h API.
    if renamex(os.fsencode(staged), os.fsencode(destination), 0x00000002):
        error = ctypes.get_errno()
        raise SystemExit(f"ERROR: Atomic app replacement failed: {os.strerror(error)}; old bundle unchanged")
else:
    os.rename(staged, destination)
PY
printf 'Built %s\n' "$app_path"
