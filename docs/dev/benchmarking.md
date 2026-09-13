# Benchmarking

The implementation does not yet have a live host/display/network baseline. No end-to-end, Game Mode, 4K60, wireless or 30-minute performance claim is made.

## Offline gates

Run `scripts/validate-offline.sh` for deterministic correctness. Run `.build/debug/swiftlight-replay --fixture fixtures/hevc-sdr8/manifest.json --mode paced --output artifacts/hevc-paced.json` for a synthetic arrival-paced offscreen workload. Replace fixture for HEVC10/AV1 variants. The short 128×72 fixtures prove integration/color/accounting; they are not a 4K60 workload or sufficient performance sample.

Replay JSON separates accepted/completed/output/no-display/skipped, outstanding/mailbox/GPU high-water marks, and timing samples/distributions. Offscreen completion is not displayed. A screenshot is not HDR validation. Timing collected with GPU API validation, sanitizers, or debugging overhead must remain labeled.

## Live baseline procedure

1. Pair through the app, using the same Sunshine/Apollo encoder, scene and display configuration as reference clients. Select HEVC SDR at 3840×2160 60 FPS and fixed bitrate; record host/encoder/client commits, macOS build, physical display mode, scale, refresh and network.
2. Warm up, then record at least three equal-duration trials using Instruments System Trace/Metal profiling. Include complete-frame assembly, admission, prepare, VT call, VT submit-to-callback, handoff, texture import, GPU execution, presentation wait, actual drawable timestamp and input/audio timing separately.
3. Compute p50/p95/p99, missing/presented/skipped counts, queue high-water, CPU/GPU use and memory. Calibrate all clocks with paired readings. Reject comparisons that call enqueue/command completion displayed or conflate predicted and actual presentation.
4. Repeat AV1 and supported10-bit/HDR paths. Validate HDR visually on the destination display with black/100–203-nit white/highlight ramps. Test same SDR content on HDR and SDR display.
5. Compare wired Ethernet and Wi-Fi, then controlled loss/reordering/path change/VPN/IPv6. Record actual socket route, not only global NWPath. Measure wired/Bluetooth audio separately.
6. Run 30 minutes at target workload, logging thermal/Low Power Mode, memory, queue bounds and frame delivery. Test display disconnect, sleep/wake, held-input disconnect, audio route change and repeated starts/stops.
7. Use native full screen and system overlay to verify Game Mode activation; compare matched enabled/disabled trials. Eligibility plist is not activation evidence.

Keep canonical output baseline. Native/lossless promotion requires an explicit reviewed decoder package API, direct Metal sampling/readback validation (including packed10-bit), and repeated measured benefit without worse tails/power. Prior decoder gains are context only and are not Swiftlight results.
