# Direct PyroWave validation — 2026-10-03

The direct production bridge decoded and rendered the four 8/10-bit × 4:2:0/4:4:4 profiles, preserved retained outputs through teardown, and recovered from damaged independent frames. The controlled 240 FPS offscreen comparison showed lower CPU preparation and admission-to-callback time. A large 120 FPS outlier prevents a claim of consistently improved tails. A separate live-host check verified rendered output and the Decode time overlay; neither check establishes sustained live performance or physical HDR acceptance.

## Implementation and correctness scope

Swiftlight's PyroWave path uses its pinned `Dependencies/pyrowave` fork through `CPyrowaveBridge`; HEVC/AV1 retain the pinned MoonlightAppleVideo path. The native bridge borrows the flattened compressed input through submit return, validates packet ranges before upstream typed loads, and passes intact records directly to the fork. Upstream coefficient concatenation and GPU upload remain. Exceptional unaligned input uses one bounded alignment copy. Decoded Y/Cb/Cr remain Metal textures owned by retained GPU leases.

`PyrowaveDecoderTests` exercises the production `VideoDecoder` and Metal renderer with test-only encoded ramps:

- 128×128 4:2:0 and odd-sized 127×97 4:4:4, each decoded to R8 and R16 planes; all three planes compared with the independent input pattern.
- Real frames rendered before and after decoder reset/destruction, with identical output and retained plane ownership.
- Independent asynchronous admission, capacity two, one-frame mailbox and exact terminal IDs.
- Finite retained-output pool backpressure, retry of the same unconsumed input, and a retained ramp verified against overwrite by subsequent neutral frames.
- Missing detail data versus missing critical data, malformed-header rejection without admission, and recovery on the next independent frame.

The full offline gate passed the four production PyroWave tests and eight HEVC/AV1 correctness replays. The native bridge's ASan/UBSan and separate TSan runs also passed parser, pending-work teardown, ring reuse, unaligned input and retained-output cases. Those sanitizer runs were separate from the timing experiment. The final record-alignment guard was rebuilt before the comparison and passed the parser sanitizer suite.

Fixtures are generated from the pinned fork by `scripts/prepare-pyrowave-fixtures.py`, with the encoder excluded from application targets. Their provenance contains the exact integer ramp, encoder revision/source/binary identities and compressed hashes. The small fixtures are 2,488 and 1,584 bytes, with SHA-256 `2bca3b7417c6226af27274035fa0e1058b19c72ccd3023553caf8d1a2656ccd6` and `c7fc2d005e5fc3eec68e1e9b567343334dd67c683be1dfea58646a1ab706844d` respectively. No captured media or existing HEVC/AV1 fixture was changed.

PyroWave's user-facing **Decode time** now uses successful output admission-to-callback measurements in a bounded 1,024-sample window. Tests check the measured value against the same output's timestamps, keep the VideoToolbox timing window empty, and reject fabricated timing for unavailable/no-output cases. This statistics addition occurred after the comparison below; its sample is appended after the native callback timestamp and does not change those recorded intervals.

## Live statistics check

The final signed Debug Xcode app resumed the paired host's already-running application without changing its saved stream profile. Rendered output was visible, and both the production bitmap panel and accessibility values showed **Decode time**. One panel observation reported 2.55 / 267.73 / 7.31 ms (minimum / maximum / mean). The received format was PyroWave, 3440×1440, 10-bit 4:2:0 with PQ/Rec.2020 metadata. The interval includes the initial large sample; it is not a steady-state benchmark.

The observed received rate was about 16 FPS with roughly 7% reported network frame loss. The short resumed Desktop stream therefore verifies the metric and actual presentation, not the requested 165 FPS cadence, bandwidth limits, loss-free operation or HDR accuracy. The check ended with a local disconnect, leaving the host application running and preserving the user's separate Release app.

After the statistics change, all 18 focused timing, sampler, statistics and hardware PyroWave tests passed. The primary macOS Xcode build, iPhone/iPad Simulator builds and signed secondary app packager also passed. Simulator builds do not establish physical mobile streaming acceptance.

## Controlled comparison

Both probes used `VideoDecoder(codec: .pyrowave)` from their respective existing Debug production modules. The preserved wrapper module/archive/header snapshot is under `artifacts/pyrowave-direct-baseline-2026-10-03/`. The direct probe was linked from current SwiftPM native objects after the final parser guard rebuild. Executables were compiled before measurement, and other agent builds, streams and GPU jobs were stopped for both blocks.

The wrapper used the local MoonlightAppleVideo route with PyroWave revision `488564aa2b5ffca0377938c27a1b67fce817c5b9`. The direct route used fork revision `f8844f16f427a94de255eb324eea66c344a3e58b`. This changes both integration route and source revision; the result cannot attribute every difference solely to wrapper removal. The preserved executable hashes are `ca397ca74070364aaf3b7ff4b9317570417f0224183e233e3f3345040106a0aa` (wrapper) and `dadfbe2056623150b780147a8046e9a8b0c62b3b834b7bc977c79ded382cc291` (direct).

The fixed input was a test-only 3440×1440 4:2:0 ramp, encoded once with a 1,000,000-byte budget to 272,284 bytes/307 packets. Both routes decoded the exact same bytes to 10-bit planes, using default precision and the same user-interactive Swift video worker. Each requested cadence used A–B–B–A order, 120 warmup frames and 480 measured frames per run, with at most two outstanding decodes. Admission ran independently of completion and retried unconsumed inputs after bounded backpressure. Each variant therefore contributed 960 measured outputs per cadence.

The machine was an Apple M3 running macOS 27.0.1 (26A434). Thermal state was nominal before/after every run and Low Power Mode was off. Those observations do not prove a constant GPU clock or scheduler state. No sanitizer or GPU capture was active during measurement.

| Requested FPS | Route | Admission → callback mean | Median | p95 | Maximum | CPU preparation mean | GPU execution mean |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 120 | Wrapper | 3.043 ms | 2.956 ms | 3.841 ms | 12.252 ms | 0.561 ms | 1.470 ms |
| 120 | Direct | 3.135 ms | 2.697 ms | 3.867 ms | 168.398 ms | 0.617 ms | 1.395 ms |
| 240 | Wrapper | 3.369 ms | 3.460 ms | 3.957 ms | 9.322 ms | 0.828 ms | 1.742 ms |
| 240 | Direct | 2.827 ms | 2.821 ms | 3.274 ms | 7.702 ms | 0.381 ms | 1.732 ms |

At 240 FPS the observed mean admission-to-callback interval decreased by 0.541 ms; CPU preparation decreased by 0.447 ms, while mean GPU execution differed by 0.011 ms. The direct runs' preparation medians were also lower. At 120 FPS a direct output spent 160.428 ms from commit to reported GPU start, and another frame recorded 157.862 ms preparation. The cause of that stall is unresolved; the samples remain included in means, percentiles and maxima.

Every run produced all 600 accepted outputs including warmup, with no failed terminals, at most two outstanding decodes, a one-frame mailbox and zero VideoToolbox timing samples. The scheduler frequently entered admission more than 0.1 ms after its requested deadline. Backpressure counts were wrapper 11/direct 24 at 120 FPS, and wrapper 18/direct 0 at 240 FPS; the 120 FPS direct block included 153.370 ms maximum admission lateness. These are scheduled synthetic admissions, not proof of displayed cadence or absence of scheduling stalls.

The compressed SHA-256 was `1232eccb4adf27dbfcc0eea18cb5ab31e3f450c0679469c20418ec0a4e266c1d`. After each timed run the production renderer produced the identical RGBA32Float checksum `0d0d943fdcac84f85f92e93dafb3a4dedd576676e3b26f1367e30c6b86064a95`. Rendering and readback were outside the timed loop. This checks matched output for this fixture without charging readback waits to production decoding.

## Evidence and limits

Per-frame samples, stage availability, queue bounds, scheduler lateness, power/thermal observations and binary identities are retained under `artifacts/pyrowave-direct-2026-10-03/abba-120/` and `abba-240/`. `comparison.json` verifies matching compressed/output hashes and workload fields. The preliminary baseline collected during concurrent CPU builds is excluded from the table. Reproduction commands are in [benchmarking](benchmarking.md#direct-pyrowave-decoder-comparison) and [video validation](video-validation.md).

This was one short ABBA block per cadence on a Debug build and one simple 4:2:0 fixture. It does not prove Release performance, large 4:4:4 behavior, 4K streaming, sustained thermal/power behavior, live loss recovery, display pacing, physical HDR or input-to-photon latency. Native/mobile compilation and simulator builds are separate from physical-device acceptance. The [September wrapper reports](pyrowave-decoder-latency-2026-09-30.md) remain historical evidence for their own workload and implementation.

## Subsequent dependency refresh

The submodule and matching revision manifest were subsequently updated to published `codex/metal-improvements` commit `56b007143b471def3e41d5e74d10f73dfc8c8df1`. Its reconstruction/render additions are guarded by `PYROWAVE_METAL_BENCH_HOOKS`; Swiftlight does not define that flag. The new experimental headers and documentation are excluded from app inputs. Production shaders, API and streaming bitstream identity remain unchanged.

The full CI gate, full offline gate (including all four PyroWave hardware tests and eight HEVC/AV1 replays), and signed primary macOS Xcode build passed against the new pin. The submodule verifier confirmed a pristine checkout and matching gitlink/manifest. The comparison and live observations above still refer to `f8844f16`; they were not remeasured for this refresh, and updating the pin does not activate the new benchmark experiments or establish a performance gain.
