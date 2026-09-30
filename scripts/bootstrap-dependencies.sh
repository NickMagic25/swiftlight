#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
repo_root="$PWD"
platform=macos
if [[ "${1:-}" == --platform && $# == 2 ]]; then
  platform="$2"
elif [[ $# != 0 ]]; then
  echo 'Usage: scripts/bootstrap-dependencies.sh [--platform macos|ios|ios-simulator|all]' >&2
  exit 2
fi
case "$platform" in
  macos|ios|ios-simulator|all) ;;
  *) echo "Unsupported dependency platform: $platform" >&2; exit 2 ;;
esac
python3 scripts/prepare-common-c.py
prefix="$repo_root/.build/dependencies"
sources="$repo_root/.build/dependency-sources"
mkdir -p "$prefix" "$sources"
fetch() {
  local archive="$1" url="$2" expected="$3"
  if [[ ! -f "$sources/$archive" ]]; then
    curl --fail --location --retry 3 "$url" -o "$sources/$archive"
  fi
  echo "$expected  $sources/$archive" | shasum -a 256 -c -
}
fetch opus-1.5.2.tar.gz https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz 65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1
fetch openssl-3.6.4.tar.gz https://github.com/openssl/openssl/releases/download/openssl-3.6.4/openssl-3.6.4.tar.gz 9bffaa1ad1e07b354c21bd3324ec02fa15579f45a7d0494b3e74bc449b7333ef
# The Xcode app packaging phase uses this shared location for every SDK.
# Publish verified notices even on clean mobile-only Cloud archive workers.
mkdir -p "$prefix/licenses"
tar -xOf "$sources/opus-1.5.2.tar.gz" opus-1.5.2/COPYING > "$prefix/licenses/Opus.txt"
tar -xOf "$sources/openssl-3.6.4.tar.gz" openssl-3.6.4/LICENSE.txt > "$prefix/licenses/OpenSSL.txt"
jobs="${SWIFTLIGHT_BUILD_JOBS:-8}"
build_macos() {
if [[ ! -f "$prefix/lib/libopus.a" ]]; then
  tar -xzf "$sources/opus-1.5.2.tar.gz" -C "$sources"
  cmake -S "$sources/opus-1.5.2" -B "$sources/opus-build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DBUILD_SHARED_LIBS=OFF \
    -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF
  cmake --build "$sources/opus-build" --parallel "$jobs"
  cmake --install "$sources/opus-build"
fi
if [[ ! -f "$prefix/lib/libcrypto.a" ]]; then
  tar -xzf "$sources/openssl-3.6.4.tar.gz" -C "$sources"
  (
    cd "$sources/openssl-3.6.4"
    case "$(uname -m)" in
      arm64) openssl_target=darwin64-arm64-cc ;;
      x86_64) openssl_target=darwin64-x86_64-cc ;;
      *) echo 'Unsupported macOS architecture' >&2; exit 1 ;;
    esac
    ./Configure "$openssl_target" no-shared no-tests no-apps \
      --prefix="$prefix" --libdir=lib -mmacosx-version-min=14.0
    make -j "$jobs"
    make install_sw
  )
fi
printf 'Opus 1.5.2\nOpenSSL 3.6.4\nArchitecture %s\n' "$(uname -m)" > "$prefix/versions.txt"
}

# Each SDK/architecture has a separate build and install tree. arm64 device and
# arm64 simulator objects are different platforms and must never share an archive.
build_mobile_slice() {
  local family="$1" arch="$2" sdk="$3" target="$4" minimum="$5"
  local slice="$family-$arch" sdk_path sdk_version stamp expected patch_sha
  local openssl_patch="$repo_root/patches/openssl/mobile-no-file-store.patch"
  local install="$prefix/$family-$arch"
  local work="$sources/$family-$arch"
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  sdk_version="$(xcrun --sdk "$sdk" --show-sdk-version)"
  patch_sha="$(shasum -a 256 "$openssl_patch")"
  patch_sha="${patch_sha%% *}"
  expected="Opus 1.5.2; OpenSSL 3.6.4; $slice; SDK $sdk_version; minimum 17.0; static-memory-getrandom-v4; patch $patch_sha"
  stamp="$install/.swiftlight-native-version"
  if [[ -f "$install/lib/libcrypto.a" && -f "$install/lib/libssl.a" && -f "$install/lib/libopus.a" &&
        -f "$install/include/openssl/configuration.h" && -f "$install/include/opus/opus.h" &&
        -f "$install/licenses/Opus.txt" && -f "$install/licenses/OpenSSL.txt" && -f "$stamp" &&
        "$(cat "$stamp")" == "$expected" ]]; then
    printf 'Native dependencies verified: %s\n' "$slice"
    return
  fi
  # This tree contains generated output only. A failed build has no completed stamp.
  rm -rf "$work" "$install"
  mkdir -p "$work" "$install"
  tar -xzf "$sources/opus-1.5.2.tar.gz" -C "$work"
  cmake -S "$work/opus-1.5.2" -B "$work/opus-build" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk_path" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DCMAKE_C_COMPILER="$(xcrun --sdk "$sdk" --find clang)" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$install" \
    -DBUILD_SHARED_LIBS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF
  cmake --build "$work/opus-build" --parallel "$jobs"
  cmake --install "$work/opus-build"
  tar -xzf "$sources/openssl-3.6.4.tar.gz" -C "$work"
  (
    cd "$work/openssl-3.6.4"
    # Stop Git discovery at the generated tree; never apply this mobile-only
    # patch to the macOS extraction or allow paths outside the extracted source.
    GIT_CEILING_DIRECTORIES="$work" git apply --check "$openssl_patch"
    GIT_CEILING_DIRECTORIES="$work" git apply "$openssl_patch"
    # Pairing and transport use memory BIOs. Remove the unused file store and
    # disable file helpers/prompts/config autoloading; retain Apple's secure RNG.
    ./Configure "$target" no-shared no-tests no-apps no-stdio no-posix-io no-ui-console no-autoload-config no-module \
      --with-rand-seed=getrandom \
      --prefix="$install" --libdir=lib "-isysroot" "$sdk_path" "$minimum"
    make -j "$jobs"
    make install_sw
  )
  mkdir -p "$install/licenses"
  tar -xOf "$sources/opus-1.5.2.tar.gz" opus-1.5.2/COPYING > "$install/licenses/Opus.txt"
  tar -xOf "$sources/openssl-3.6.4.tar.gz" openssl-3.6.4/LICENSE.txt > "$install/licenses/OpenSSL.txt"
  printf '%s\n' "$expected" > "$stamp"
}

publish_mobile() {
  local family="$1"
  shift
  local first="$1" arch library
  local destination="$prefix/$family" headers="$prefix/mobile/include"
  mkdir -p "$destination/lib" "$headers/openssl"
  # All installed public headers are shared except OpenSSL's generated configuration.
  # Keep that header per slice and dispatch using compiler target macros, never host uname.
  cp -R "$prefix/$family-$first/include/" "$headers/"
  for arch in "$@"; do
    cp "$prefix/$family-$arch/include/openssl/configuration.h" \
      "$headers/openssl/configuration-$family-$arch.h"
  done
  cat > "$headers/openssl/configuration.h" <<'HEADER'
/* Generated by Swiftlight dependency bootstrap. */
#include <TargetConditionals.h>
#if TARGET_OS_SIMULATOR && defined(__aarch64__)
#include <openssl/configuration-ios-simulator-arm64.h>
#elif TARGET_OS_SIMULATOR && defined(__x86_64__)
#include <openssl/configuration-ios-simulator-x86_64.h>
#elif TARGET_OS_IOS && defined(__aarch64__)
#include <openssl/configuration-ios-arm64.h>
#else
#error Unsupported Swiftlight mobile native dependency target
#endif
HEADER
  for library in crypto ssl opus; do
    local inputs=()
    for arch in "$@"; do inputs+=("$prefix/$family-$arch/lib/lib$library.a"); done
    xcrun lipo -create "${inputs[@]}" -output "$destination/lib/lib$library.a.tmp"
    mv -f "$destination/lib/lib$library.a.tmp" "$destination/lib/lib$library.a"
  done
  mkdir -p "$destination/licenses"
  cp "$prefix/$family-$first/licenses/"*.txt "$destination/licenses/"
  cat "$prefix/$family-$first/.swiftlight-native-version" > "$destination/versions.txt"
}

if [[ "$platform" == macos || "$platform" == all ]]; then build_macos; fi
if [[ "$platform" == ios || "$platform" == all ]]; then
  build_mobile_slice ios arm64 iphoneos ios64-xcrun -miphoneos-version-min=17.0
  publish_mobile ios arm64
fi
if [[ "$platform" == ios-simulator || "$platform" == all ]]; then
  build_mobile_slice ios-simulator arm64 iphonesimulator iossimulator-arm64-xcrun -mios-simulator-version-min=17.0
  build_mobile_slice ios-simulator x86_64 iphonesimulator iossimulator-x86_64-xcrun -mios-simulator-version-min=17.0
  publish_mobile ios-simulator arm64 x86_64
fi
