#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p artifacts .build/ModuleCache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTLIGHT_RUN_HARDWARE_TESTS=1
scripts/bootstrap-dependencies.sh
swift test --disable-sandbox --manifest-cache none
python3 docs/host-otp-vectors.py
python3 -m unittest discover -s Tests/DependencyPreparation -v
scripts/validate-transport-native.sh
for fixture in hevc-sdr8 hevc-hdr10 av1-sdr8 av1-hdr10 av1-accounting-8 av1-accounting-10 hevc-reconfigure av1-reconfigure; do
  .build/debug/swiftlight-replay --fixture "fixtures/$fixture/manifest.json" --mode correctness --output "artifacts/$fixture-correctness.json"
done
python3 scripts/audit-decoder.py
python3 scripts/acceptance-report.py
