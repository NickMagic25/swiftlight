#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/prepare-common-c.py
mkdir -p .build/native-transport-tests
bridge=Sources/CStreamBridge
common="$bridge/vendor/common-c"
files=("$bridge/StreamBridge.c" "$bridge/AudioRing.c" "$bridge/AudioOutput.c" "$bridge/AudioFormat.c" "$bridge/AudioSpatialOutput.m" "$common"/src/*.c
 "$common"/enet/{callbacks,compress,host,list,packet,peer,protocol,unix}.c
 "$common/nanors/rs.c" "$common/nanors/deps/obl/oblas_common.c" "$common/nanors/deps/obl/oblas_lite.c")
xcrun clang -std=gnu11 -fblocks -g -O1 -fsanitize="${SWIFTLIGHT_SANITIZERS:-address,undefined}" \
 -D__APPLE_USE_RFC_3542 -DHAS_SOCKLEN_T -DHAS_FCNTL -DHAS_POLL -DHAS_GETADDRINFO \
 -DHAS_GETNAMEINFO -DHAS_INET_PTON -DHAS_INET_NTOP -DHAS_MSGHDR_FLAGS -DNDEBUG \
 -I"$bridge/include" -I"$common/src" -I"$common/enet/include" -I"$common/nanors" \
 -I"$common/nanors/deps" -I"$common/nanors/deps/obl" -I.build/dependencies/include \
 "${files[@]}" Tests/NativeTransport/main.c .build/dependencies/lib/libcrypto.a \
 .build/dependencies/lib/libopus.a -framework AudioToolbox -framework CoreAudio -framework CoreMedia -framework AVFoundation -framework Foundation \
 -o .build/native-transport-tests/validate
.build/native-transport-tests/validate | tee .build/native-transport-tests/results.json
# Independently link the real RTP queue against no-host callbacks so packet-loss
# scenarios cannot mutate common-c's process-global live connection state.
xcrun clang -std=gnu11 -g -O1 -fsanitize="${SWIFTLIGHT_SANITIZERS:-address,undefined}" \
 -D__APPLE_USE_RFC_3542 -DNDEBUG -I"$common/src" -I"$common/enet/include" \
 -I"$common/nanors" -I"$common/nanors/deps" -I"$common/nanors/deps/obl" -I.build/dependencies/include \
 "$common/src/RtpVideoQueue.c" "$common/nanors/rs.c" \
 "$common/nanors/deps/obl/oblas_common.c" "$common/nanors/deps/obl/oblas_lite.c" \
 Tests/NativeTransport/network_frames.c -o .build/native-transport-tests/network-frames
.build/native-transport-tests/network-frames | tee .build/native-transport-tests/network-frames-results.json
# Test speaker labels, downmix impulses, CoreMedia ownership/timestamps without
# opening a device. Set SWIFTLIGHT_AUDIO_SMOKE=1 for short, quiet local playback.
xcrun clang -std=gnu11 -fblocks -g -O1 -fsanitize="${SWIFTLIGHT_SANITIZERS:-address,undefined}" \
 -I"$bridge" -I"$bridge/include" -I.build/dependencies/include \
 "$bridge/AudioOutput.c" "$bridge/AudioRing.c" "$bridge/AudioFormat.c" "$bridge/AudioSpatialOutput.m" \
 Tests/NativeTransport/audio.m .build/dependencies/lib/libopus.a \
 -framework AudioToolbox -framework CoreAudio -framework CoreMedia -framework AVFoundation -framework Foundation \
 -o .build/native-transport-tests/audio
.build/native-transport-tests/audio | tee .build/native-transport-tests/audio-results.json
# Exercise a real renderer replacement, stale notifications, and teardown with
# asynchronous removal pending. This test opens the current audio output and
# therefore only runs with the explicit quiet-playback smoke option.
if [[ "${SWIFTLIGHT_AUDIO_SMOKE:-0}" == "1" ]]; then
 xcrun clang -std=gnu11 -fblocks -g -O1 -fsanitize="${SWIFTLIGHT_SANITIZERS:-address,undefined}" \
  -I"$bridge" -I"$bridge/include" -I.build/dependencies/include \
  "$bridge/AudioRing.c" "$bridge/AudioFormat.c" Tests/NativeTransport/audio_recovery.m \
  -framework AudioToolbox -framework CoreAudio -framework CoreMedia -framework AVFoundation -framework Foundation \
  -o .build/native-transport-tests/audio-recovery
 .build/native-transport-tests/audio-recovery | tee .build/native-transport-tests/audio-recovery-results.json
fi
