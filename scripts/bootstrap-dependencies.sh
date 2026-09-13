#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
repo_root="$PWD"
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
jobs="${SWIFTLIGHT_BUILD_JOBS:-8}"
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
mkdir -p "$prefix/licenses"
tar -xOf "$sources/opus-1.5.2.tar.gz" opus-1.5.2/COPYING > "$prefix/licenses/Opus.txt"
tar -xOf "$sources/openssl-3.6.4.tar.gz" openssl-3.6.4/LICENSE.txt > "$prefix/licenses/OpenSSL.txt"
printf 'Opus 1.5.2\nOpenSSL 3.6.4\nArchitecture %s\n' "$(uname -m)" > "$prefix/versions.txt"
