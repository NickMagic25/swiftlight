# Benchmarking

Keep current measurements separate from dated reports, including the [September PyroWave investigation](pyrowave-decoder-latency-2026-09-30.md). Those reports describe the source revision, route and workload they recorded. No offscreen decode result establishes end-to-end latency, Game Mode, wireless behavior or a 30-minute stream.

## Offline gates

Run `scripts/validate-offline.sh` for deterministic correctness. Run `.build/debug/swiftlight-replay --fixture fixtures/hevc-sdr8/manifest.json --mode paced --output artifacts/hevc-paced.json` for a synthetic arrival-paced offscreen workload. Replace fixture for HEVC10/AV1 variants. The short 128×72 fixtures prove integration/color/accounting; they are not a 4K60 workload or sufficient performance sample.

Replay JSON separates accepted/completed/output/no-display/skipped, outstanding/mailbox/GPU high-water marks, and timing samples/distributions. Offscreen completion is not displayed. A screenshot is not HDR validation. Timing collected with GPU API validation, sanitizers, or debugging overhead must remain labeled.

## Direct PyroWave decoder comparison

Build the shared modules and generate one larger test-only input outside the measurement loop:

```sh
swift build --build-system native --product swiftlight-replay
python3 scripts/prepare-pyrowave-fixtures.py --benchmark
python3 scripts/benchmark-pyrowave.py \
  --fixture .build/pyrowave-fixtures/pyrowave-3440x1440-420.bin \
  --fps 240 --frames 480 --warmup 120 --depth 10 \
  --output artifacts/pyrowave-direct-240.json
```

The probe compiles against the existing production `SwiftlightVideo` module and current native link objects. Admission runs independently at fixed cadence with capacity two; it retries the same unconsumed input after bounded backpressure and requires exact output/terminal counts. It records same-frame admission-to-callback and available preparation/backend/GPU intervals, queue bounds and admission lateness. Empty stage summaries mean unavailable, never zero. The final production-renderer RGB checksum is taken after timing. No network, renderer latency, window presentation, physical display or input-to-photon latency is measured.

For a wrapper/direct comparison, retain the wrapper's matching Swift module, native archive, headers and executable before changing dependencies. Run the same immutable compressed bytes, dimensions, depth, chroma, precision, worker QoS, two-frame capacity, warmup and cadence in A–B–B–A order while other builds, streams and GPU jobs are stopped. Repeat at 120 and 240 FPS; retain per-frame samples, missing counts, p95/tails, thermal/power state, source identities and exact output hashes. A changed fork revision is an additional variable: such a comparison measures the combined source/dependency route change and cannot attribute every gain to removing a wrapper. Sequential completion waits and unpaced bursts answer different questions and must remain separate from this cadence experiment.

Use `--compile-only` with `benchmark-pyrowave.py` to prepare each executable before the quiet measurement window. Then run `compare-pyrowave.py --wrapper <preserved-executable> --direct <direct-executable> --fixture <fixed-input> --fps 240 --output-dir artifacts/pyrowave-abba-240`. It launches only the two existing probes, retains all four reports and rejects a comparison with mismatched fixture/output hashes, profile, cadence or sample count. Compilation and fixture encoding never run between variants.

## Live baseline procedure

1. Pair through the app, using the same Sunshine/Apollo encoder, scene and display configuration as reference clients. Select HEVC SDR at 3840×2160 60 FPS and fixed bitrate; record host/encoder/client commits, macOS build, physical display mode, scale, refresh and network.
2. Warm up, then record at least three equal-duration trials using Instruments System Trace/Metal profiling. Include complete-frame assembly, admission, prepare, VT call, VT submit-to-callback, handoff, texture import, GPU execution, presentation wait, actual drawable timestamp and input/audio timing separately.
3. Compute p50/p95/p99, missing/presented/skipped counts, queue high-water, CPU/GPU use and memory. Calibrate all clocks with paired readings. Reject comparisons that call enqueue/command completion displayed or conflate predicted and actual presentation.
4. Repeat AV1 and supported10-bit/HDR paths. Validate HDR visually on the destination display with black/100–203-nit white/highlight ramps. Test same SDR content on HDR and SDR display.
5. Compare wired Ethernet and Wi-Fi, then controlled loss/reordering/path change/VPN/IPv6. Record actual socket route, not only global NWPath. Measure wired/Bluetooth audio separately.
6. Run 30 minutes at target workload, logging thermal/Low Power Mode, memory, queue bounds and frame delivery. Test display disconnect, sleep/wake, held-input disconnect, audio route change and repeated starts/stops.
7. Use native full screen and system overlay to verify Game Mode activation; compare matched enabled/disabled trials. Eligibility plist is not activation evidence.

Keep canonical output baseline. Native/lossless promotion requires an explicit reviewed decoder package API, direct Metal sampling/readback validation (including packed10-bit), and repeated measured benefit without worse tails/power. Prior decoder gains are context only and are not Swiftlight results.
