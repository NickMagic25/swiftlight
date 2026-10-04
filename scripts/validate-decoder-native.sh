#!/bin/bash
# Exercise the in-repository decoder's native ownership, ABI and bitstream tests.
set -euo pipefail
cd "$(dirname "$0")/.."
decoder_root="$PWD/Packages/moonlight-apple-decoder"
decoder_build="$PWD/.build/decoder-native-tests"
cmake -S "$decoder_root" -B "$decoder_build" \
  -DCMAKE_BUILD_TYPE=Debug -DBUILD_TESTING=ON -DMAV_BUILD_TOOLS=OFF \
  -DMAV_VT_EXPERIMENTS=OFF
cmake --build "$decoder_build" --parallel "${SWIFTLIGHT_BUILD_JOBS:-4}"
if [[ "${SWIFTLIGHT_RUN_HARDWARE_TESTS:-0}" == 1 ]]; then
  ctest --test-dir "$decoder_build" --output-on-failure
else
  ctest --test-dir "$decoder_build" --output-on-failure --exclude-regex '^pyrowave-metal$'
fi
