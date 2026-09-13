# Offline video validation

Run the repository's `scripts/validate-offline.sh` on a Mac with hardware HEVC/AV1 decoding and Metal access. The suite must report unavailable codecs as BLOCKED, never PASS. A fresh checkout uses the committed synthetic fixtures, without Sunshine, credentials, encoders, or downloads beyond initial source dependencies.

Individual commands after `swift build --product swiftlight-replay`:

```sh
.build/debug/swiftlight-replay --fixture fixtures/hevc-sdr8/manifest.json --mode correctness --output artifacts/hevc-sdr8-correctness.json
.build/debug/swiftlight-replay --fixture fixtures/hevc-hdr10/manifest.json --mode correctness --output artifacts/hevc-hdr10-correctness.json
.build/debug/swiftlight-replay --fixture fixtures/av1-sdr8/manifest.json --mode correctness --output artifacts/av1-sdr8-correctness.json
.build/debug/swiftlight-replay --fixture fixtures/av1-hdr10/manifest.json --mode correctness --output artifacts/av1-hdr10-correctness.json
.build/debug/swiftlight-replay --fixture fixtures/av1-accounting-8/manifest.json --mode correctness --output artifacts/av1-accounting-8-correctness.json
.build/debug/swiftlight-replay --fixture fixtures/av1-accounting-10/manifest.json --mode correctness --output artifacts/av1-accounting-10-correctness.json
.build/debug/swiftlight-replay --fixture fixtures/hevc-sdr8/manifest.json --mode paced --output artifacts/hevc-sdr8-paced.json
SWIFTLIGHT_RUN_HARDWARE_TESTS=1 swift test --filter VideoTests
```

Correctness mode uses the production owner, accepted/terminal bookkeeping, latest-frame handoff, CoreVideo texture import, and production Metal shader. It drains one access unit at a time to check exact frame identity, dimensions, depth, hardware output, and display count. Every visible RGB sample is compared against a CPU double-precision reference derived from decoded Y/UV pixels, including real chroma interpolation and the declared matrix/transfer/primaries. CPU mapping and completion waits exist only in this diagnostic path. The final buffer is rendered again after decoder reset and destruction; all retained-frame owners must then return to zero.

The shader comparison establishes correct interpretation of the decoded canonical buffer; it is not an independent decoder correctness oracle for the compressed content. Fixtures remain simple synthetic moving patterns with exact compressed hashes and expected dimensions/output counts. Full independent compressed-decoder pixel equivalence is a separate unexecuted gate for this client. Do not turn this shader test into a claim of native packed-format correctness.

The ordinary test target runs malformed/empty/truncated-real-AU synchronous rejection and create/drain/reset/destroy without hardware claims. Hardware tests additionally exercise configuration-only inline no-display completion, ownership past destruction, two-frame decoder capacity and latest-frame replacement, reset with accepted work and required new random-access input, 128x72 SDR8 to 192x104 HDR10 configuration changes while work is pending, and 24 NV12/P010 full/video-range/chroma-location cases containing ramps, varying saturated chroma and padded/cropped dimensions.

`testDrawableCallbackCanFinishDuringHandlerRegistration` reproduces the live stream's opposing drawable-callback lock order with a bounded synthetic `MTLDrawable`: registration waits for a concurrent presented callback to return. It uses the production encoder, real GPU commit/completion and metrics, while replacing actual window presentation with no action. It passed with Metal API validation after separating encoding and metrics locks and moving drawable operations outside them. This is a lock-order regression, not evidence of visible presentation or physical latency.

The AV1 accounting fixtures each contain 71 complete coded-frame units: 48 displayed outputs, 23 hidden/no-display completions and 20 show-existing events. They use the same production adapter and shader validation, with independently enumerated coded-frame boundaries from the pinned fixture-preparation parser. Replay checks all expected totals and frame identities. This is client-adapter evidence, separate from upstream decoder test results.

Paced mode schedules AUs at the fixture's synthetic arrival times, reuses an offscreen target, permits latest-frame skips, bounds GPU work, and reports decoder/GPU timings. It has no display surface and therefore records zero actual presentations. Its short eight-frame fixtures are smoke coverage, not a statistically meaningful gaming latency benchmark, display-pacing verification, or network measurement. Run representative captured streams with longer recorded timing before setting numerical overhead budgets.

The app's **Stream → Video Validation** window provides a separate visible fixture replay through `CAMetalDisplayLink`, the production decoder, and the production Metal renderer. Choose a manifest or fixture folder. With Loop disabled, **Completed** means compressed input has drained; the decoder and final mailbox/view frame remain retained so even a one-frame fixture can reach a display tick. **Stop** stays available and closes the decoder; window close does the same. New Play waits for old decoder destruction before starting a replacement. A Completed export may therefore legitimately report a live frame owner. Stop clears the preview's owners, while pending GPU work and other app windows can keep process-wide ownership nonzero until their work finishes.

Visible replay exports separately report terminal accounting and observed positive drawable presentation timestamps. `lateDisplayLinkCallbacks` compares callback entry with the supplied submission deadline; it does not measure when encoding or submission finished. This window and its counters do not by themselves establish physical HDR behavior or live-host latency. Actual visible presentation results must come from a separately executed window run.

After building `Swiftlight`, run `python3 scripts/validate-preview-lifecycle.py` for a focused, server-free hardware regression. It compiles the exact preview source with a same-file harness, reads one real HEVC access unit, checks final mailbox retention, explicit Stop, retained output after teardown, restart destruction ordering, cancellation of queued Play, and honest report status/metric naming. It opens no window and cannot validate actual presentation. Select another existing SwiftPM debug directory with `--build-dir` when needed.

That lifecycle regression passed on the development Mac with hardware HEVC decoding, all seven checks satisfied, and zero live frame owners after Stop. Its JSON explicitly records `visiblePresentationMeasured: false`; this result does not clear the visible-display acceptance gate.

Color output is extended linear sRGB. BT.709/BT.601 matrices and SDR transfer signaling are supported alongside BT.2020 nonconstant-luminance/PQ. PQ maps 203 nits to 1.0 EDR; BT.2020 primaries are transformed into the declared linear sRGB layer space. The surface must configure the matching floating-point drawable, extended-linear color space and system tone mapping. This offscreen test does not verify display EDR headroom changes, HDR-to-SDR behavior, physical nits, or mastering/content-light-driven system tone mapping. HLG, other primaries/matrices, and packed native/lossless buffers reject visibly.

Regeneration uses a development-only fixture encoder from decoder revision `8d92ee039dc19fe50dc0158d5098d4c5646c6a56`:

```sh
# In the decoder checkout, build mav-fixture and bootstrap its development AV1 encoder.
cmake -S ../moonlight-apple-decoder -B ../moonlight-apple-decoder/build -DCMAKE_BUILD_TYPE=Release
cmake --build ../moonlight-apple-decoder/build --target mav-fixture --parallel 4
../moonlight-apple-decoder/scripts/bootstrap-aom.sh
python3 scripts/generate-fixtures.py --decoder ../moonlight-apple-decoder
python3 scripts/generate-fixtures-accounting.py --decoder ../moonlight-apple-decoder
```

Fixture media is generated from the decoder's synthetic pattern, contains no third-party audiovisual material, and is distributed under this repository's license. The manifests retain encoder identity, OS, color metadata, frame boundaries and SHA-256 hashes; `fixtures/provenance.json` also records exact generator binary identities. Hardware HEVC encoders are OS-versioned: regeneration may produce different compressed hashes while preserving the expected properties.

The real accounting fixtures, four baseline codec/depth fixtures, and both configuration-change fixtures have passed hardware decoding and Metal readback on the development Mac. Six video tests passed with AddressSanitizer and Metal API validation enabled. The ASan AV1 10-bit accounting replay also passed with 48 buffer owners acquired/released and zero live owners after teardown. ASan was run with leak detection disabled; those explicit counters cover retained frame owners, while long-running process-wide leak/soak testing remains unverified.

Reproduce the sanitizer configuration with the installed Xcode toolchain (select its direct test-runner path so system xcrun does not strip the injection environment):

```sh
swift test --scratch-path .build-asan --sanitize address --filter VideoTests
swiftlight_asan_runtime="$(xcrun clang --print-resource-dir)/lib/darwin/libclang_rt.asan_osx_dynamic.dylib"
swiftlight_xctest="$(xcrun --find xctest)"
SWIFTLIGHT_RUN_HARDWARE_TESTS=1 MTL_DEBUG_LAYER=1 ASAN_OPTIONS=detect_leaks=0 \
  DYLD_INSERT_LIBRARIES="$swiftlight_asan_runtime" "$swiftlight_xctest" \
  -XCTest SwiftlightVideoTests.VideoTests .build-asan/debug/SwiftlightPackageTests.xctest
MTL_DEBUG_LAYER=1 ASAN_OPTIONS=detect_leaks=0 .build-asan/debug/swiftlight-replay \
  --fixture fixtures/av1-accounting-10/manifest.json --mode correctness \
  --output artifacts/av1-accounting-10-asan-correctness.json
```

Remaining coverage includes real Sunshine encoder interoperability (especially HEVC low-delay B pictures), additional encoded crop/sample-aspect-ratio edge cases, long-running process-wide retention/soak, and live SDR/HDR display/performance validation. These remain TODO/BLOCKED in the acceptance matrix until separately executed; upstream decoder tests do not substitute for client-adapter evidence.
