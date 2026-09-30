#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Bootstrap ios-simulator first. Supply a booted simulator UDID when more than
# one is running. This executes the real mobile static crypto build, no Keychain.
simulator="${1:-booted}"
output="$PWD/.build/native-mobile-tests"
mkdir -p "$output"
arch="$(uname -m)"
xcrun --sdk iphonesimulator clang -target "$arch-apple-ios17.0-simulator" \
  -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" -std=c11 -Wall -Wextra -Werror -DSWIFTLIGHT_EXPECT_NO_FILE_STORE \
  -I Sources/shared/CHostCrypto/include -I .build/dependencies/mobile/include \
  Sources/shared/CHostCrypto/HostCrypto.c Tests/NativeHostCrypto/main.c \
  -L .build/dependencies/ios-simulator/lib -lcrypto -o "$output/crypto"
# A linked default/base file-store registration must not survive the mobile
# source patch. Keep the import report and fail on filesystem metadata APIs.
xcrun nm -u "$output/crypto" > "$output/crypto-imports.txt"
python3 - "$output/crypto-imports.txt" <<'PYTHON'
from pathlib import Path
import re
import sys
imports = Path(sys.argv[1]).read_text()
if re.search(r"(?m)^\s*(?:U\s+)?_(?:stat|fstat|lstat)(?:\$[^\s]+)?$", imports):
    raise SystemExit("Mobile crypto unexpectedly imports filesystem metadata APIs")
PYTHON
xcrun simctl spawn "$simulator" "$output/crypto" | tee "$output/crypto-results.json"
