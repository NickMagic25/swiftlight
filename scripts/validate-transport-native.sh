#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/prepare-common-c.py
mkdir -p .build/native-transport-tests
bridge=Sources/CStreamBridge
common="$bridge/vendor/common-c"
files=("$bridge/StreamBridge.c" "$bridge/AudioRing.c" "$bridge/AudioOutput.c" "$common"/src/*.c
 "$common"/enet/{callbacks,compress,host,list,packet,peer,protocol,unix}.c
 "$common/nanors/rs.c" "$common/nanors/deps/obl/oblas_common.c" "$common/nanors/deps/obl/oblas_lite.c")
xcrun clang -std=gnu11 -fblocks -g -O1 -fsanitize="${SWIFTLIGHT_SANITIZERS:-address,undefined}" \
 -D__APPLE_USE_RFC_3542 -DHAS_SOCKLEN_T -DHAS_FCNTL -DHAS_POLL -DHAS_GETADDRINFO \
 -DHAS_GETNAMEINFO -DHAS_INET_PTON -DHAS_INET_NTOP -DHAS_MSGHDR_FLAGS -DNDEBUG \
 -I"$bridge/include" -I"$common/src" -I"$common/enet/include" -I"$common/nanors" \
 -I"$common/nanors/deps" -I"$common/nanors/deps/obl" -I.build/dependencies/include \
 "${files[@]}" Tests/NativeTransport/main.c .build/dependencies/lib/libcrypto.a \
 .build/dependencies/lib/libopus.a -framework AudioToolbox -framework CoreAudio \
 -o .build/native-transport-tests/validate
.build/native-transport-tests/validate | tee .build/native-transport-tests/results.json
