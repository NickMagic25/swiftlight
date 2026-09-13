#!/bin/bash
# Host-independent release checks; real decoder/Metal acceptance remains in validate-offline.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p artifacts .build/ModuleCache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTLIGHT_RUN_HARDWARE_TESTS=0
export SWIFTLIGHT_AUDIO_SMOKE=0
scripts/bootstrap-dependencies.sh
swift test --disable-sandbox --manifest-cache none
python3 docs/dev/host-otp-vectors.py
python3 -m unittest discover -s Tests/DependencyPreparation -v
python3 -m unittest discover -s Tests/Release -v
python3 Tests/BuildPackaging/test_build_app.py --output artifacts/build-packaging.json
scripts/validate-transport-native.sh
cp .build/native-transport-tests/*results.json artifacts/
python3 scripts/validate-artwork-store.py
python3 scripts/validate-display-publication.py
python3 scripts/validate-stream-window-lifecycle.py
python3 scripts/audit-decoder.py
