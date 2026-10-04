#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/verify-pyrowave.py
mode="${1:-address}"
fixture420="${2:-.build/pyrowave-fixtures/pyrowave-128x128-420.bin}"
fixture444="${3:-.build/pyrowave-fixtures/pyrowave-127x97-444.bin}"
output="$PWD/.build/pyrowave-native-$mode"
mkdir -p "$output/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$output/ModuleCache"
flags=(-std=c++23 -O2 -g -fno-omit-frame-pointer -include "$PWD/Sources/shared/CPyrowaveBridge/Private/PyrowaveSymbols.h"
    -I "$PWD/Sources/shared/CPyrowaveBridge/include" -I "$PWD/Sources/shared/CPyrowaveBridge" -I "$PWD/Dependencies/pyrowave/metal")
case "$mode" in
    address) flags+=(-fsanitize=address,undefined) ;;
    thread) flags+=(-fsanitize=thread) ;;
    none) ;;
    *) echo "Usage: $0 [address|thread|none] [420-fixture] [444-fixture]" >&2; exit 2 ;;
esac
handoff=(Sources/shared/CPyrowaveBridge/SPyrowaveInput.cpp)
xcrun clang++ "${flags[@]}" Tests/PyrowaveNative/framing.cpp "${handoff[@]}" -o "$output/framing"
"$output/framing"
if [[ "${SWIFTLIGHT_PYROWAVE_CPU_ONLY:-0}" == 1 ]]; then exit 0; fi
if [[ ! -f "$fixture420" || ! -f "$fixture444" ]]; then
    echo "Native Metal checks require the encoded ramp fixtures; pass their paths as arguments." >&2
    exit 2
fi
xcrun clang++ "${flags[@]}" -fobjc-arc -fmodules Tests/PyrowaveNative/metal.mm \
    Sources/shared/CPyrowaveBridge/SPyrowave.mm "${handoff[@]}" Dependencies/pyrowave/metal/pyrowave_bitstream.cpp \
    Dependencies/pyrowave/metal/pyrowave_common.mm Dependencies/pyrowave/metal/pyrowave_decoder.mm \
    -framework Metal -framework Foundation -framework QuartzCore -framework IOSurface -o "$output/metal"
"$output/metal" "$fixture420" "$fixture444"
