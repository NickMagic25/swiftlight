# Continued presentation-latency investigation — September 13, 2026

The default now presents on decoded-frame arrival, with VSync off and three
available drawables. This adopts the measured presentation-policy improvement
from the [first investigation](stream-latency-debugging.md), while preserving
explicitly saved preferences. It is not a claim of minimum physical scanout latency
on every display. HDR caching/ordering, native PQ, and root-layer alternatives
remain debug experiments; the tested alternatives did not establish a safe,
repeatable improvement to ship by default.

## Controlled measurements

Six sequential 50-second Desktop connections used 3440 × 1440 HEVC HDR10,
165 requested FPS, 350 Mbps requested bitrate, native fullscreen, VSync off,
three drawables, captured input, statistics hidden, and the Metal HUD enabled.
Actual runtime exports verified the external display's 165 Hz rate and equal
minimum/maximum refresh intervals of 6.060916 ms. Thermal state was normal.
TestUFO remained a moving workload; its browser reported a synchronization failure,
so it was not a physical motion/tearing reference. Incoming stream FPS was measured
independently by SwiftLight.

All 18 live checkpoints, taken at 10, 30, and 50 seconds, are retained in
`artifacts/latency-optimization-2026-09-13/controlled/`. The run ID is
`comparison-1789283070183-1C0AA572`; executable SHA-256 was
`5474ff08f72ff6c6f53ff4d8d06d6f592c17fa83dd33be30a995dc7dfdbb38c9`.
`controlled-analysis.json` and `.txt` contain the parser output. Artifacts are
ignored by Git. Each row below uses its separate final 1,024 completed-submission
window. The rates derive from those timestamp intervals, not the entire session.
No overlapping timeline snapshots were pooled.

| Case | Packet → GPU end mean / p95 | Drawable acquisition mean | Completion rate |
|---|---:|---:|---:|
| Existing HDR placement, scheduled callback on | 4.822 / 5.781 ms | 0.059 ms | 165.0 FPS |
| Same, scheduled callback off | 4.314 / 6.827 ms | 0.044 ms | 165.0 FPS |
| HDR metadata assigned before acquisition each frame | 7.650 / 10.464 ms | 4.623 ms | 120.0 FPS |
| Existing HDR placement, empty overlay container removed | 7.638 / 10.654 ms | 8.410 ms | 112.1 FPS |
| Same, root Metal layer | 7.563 / 10.465 ms | 8.767 ms | 108.1 FPS |
| Root layer, native PQ, metadata nil | 7.343 / 10.267 ms | 4.701 ms | 119.9 FPS |

Removing the scheduled callback did not consistently improve decoded-frame
latency. The lower packet-to-GPU mean in that case partly came from faster decoding.
The two existing-HDR cases have these complete, same-frame additive stages:

| Stage mean | Scheduled callback on | Off |
|---|---:|---:|
| Decode callback → render start | 0.2774 ms | 0.1963 ms |
| CPU render → commit | 0.2621 ms | 0.1816 ms |
| Commit → GPU start | 0.4943 ms | 0.3819 ms |
| GPU execution | 0.9376 ms | 1.3172 ms |
| **Decoded → GPU end total** | **1.9714 ms** | **2.0771 ms** |
| Total p95 | 2.8592 ms | 4.4756 ms |

These stages sum to their paired totals within floating-point precision. Drawable
acquisition overlaps the selected frame's decode/selection path and must not be
added again. The immediate experimental path reselects the latest frame after a
blocking acquisition; frames superseded there are not counted by the decoder's
mailbox replacement counter alone. Completion windows include redraw submissions,
whereas confirmed-presentation windows deduplicate decoded frames.

## A real 120 Hz cadence, with an unresolved source

The affected cases have a stable approximately 8.333 ms submission clock.
Fitting commit timestamps to the nearest 8.333 ms tick gives 8.33328–8.33376 ms
periods and approximately 0.58–0.65 ms phase residual p95. The two overlay/root
cases additionally have occasional three-tick, approximately 25 ms gaps. Their
GPU-start intervals agree. The original-placement cases instead average
6.0618 and 6.0603 ms between commits.

This is stronger evidence than merely averaging 120 FPS. It does not identify
which OS component produced that cadence and does not prove that the MacBook's
internal ProMotion display is the cause. Changing frame-selection queues or
removing the empty overlay did not resolve it. Assigning metadata before acquisition
reproduced the slowdown even without caching, so caching alone is not the cause.

## Presentation telemetry and the Metal HUD

Every presentation callback in these six runs supplied an unusable zero
`presentedTime`, despite visibly advancing video. Disabling our custom scheduled
callback did not restore it. No confirmed first-packet-to-display or GPU-end-to-display
latency can be claimed from these exports. GPU completion is not scanout; CPU
completion notification is also not scanout. Some variants had large callback
notification delays after the GPU had already finished.

The Metal HUD was visually observed reporting **Composited** on the existing
linear HDR path, including a run with the SwiftLight statistics overlay hidden.
Its separately observed Present Delay changed across runs; a HUD rolling mean
cannot be combined with an independent per-frame window to invent end-to-end latency.
A separate native PQ/root-layer preview also visibly reported **Composited**,
with a HUD observation of 1.89 ms GPU time and 17.27 ms Present Delay. Those are
independent HUD rolling values, not an additive per-frame trace. Its finalized
export is retained as `native-pq-preview-stream-*.json`.
Root-layer runtime identity alone does not establish direct-to-display. Apple documents fullscreen, opaque surfaces and
other eligibility constraints; overlapping system/app surfaces can still require
composition. [Apple presentation guidance](https://developer.apple.com/documentation/metal/managing-your-game-window-for-metal-in-macos).

## HDR and ProMotion API findings

Apple requires `edrMetadata` to be set before obtaining the affected drawable.
Non-nil metadata requires a linear color space and a floating-point format
supporting values above 1.0. The current metadata-placement behavior is retained
as the measured baseline while the compliant alternatives are investigated;
it has not been silently replaced by the slower experiment.
[EDR metadata contract](https://developer.apple.com/documentation/quartzcore/cametallayer/edrmetadata).

The native PQ experiment uses BT.2020 PQ shader output, `bgr10a2Unorm`,
`itur_2100_PQ`, extended dynamic range, and nil legacy EDR metadata. Four hardware
readback tests cover neutral values, colored patches, packed targets and mode
changes. They validate shader values, not monitor tone mapping or physical HDR
color. On modern macOS, `CALayer.toneMapMode` can independently tone-map HDR;
nil legacy metadata does not imply that all system tone mapping is disabled.
Native PQ and explicit tone-map policies need further color and latency validation.
[HDR color spaces](https://developer.apple.com/documentation/metal/using-color-spaces-to-display-hdr-content),
[tone-map mode](https://developer.apple.com/documentation/quartzcore/calayer/tonemapmode-swift.property).

The optional display-paced mode already uses `CAMetalDisplayLink` with minimum
supported preferred frame latency 1. Its frame-rate preference is refreshed when
the window's display changes. The immediate default does not wait for that callback.
A frame-rate range describes callback preferences; it is not an HDR-processing
speed control or a guarantee of direct presentation. The tested external display
was fixed at 165 Hz, so no ProMotion benefit was measured.

## Reproduction and validation

Use Stream → Run Latency Comparison (Short/Full) in the Debug app. Short runs the
first three cases above; Full runs all six. Checkpoints now persist in
`~/Library/Application Support/Swiftlight/LatencyExperiments/`. The runner verifies
connection generation, fullscreen, capture, display geometry and statistics
visibility, disconnects locally between runs, and restores settings afterward.
The host Desktop remains running. The native PQ/root-layer preview and reset
commands configure only the next stream and do not save host preferences.

The full Swift suite passed 91 tests (66 XCTest and 25 host Swift Testing cases),
including real VideoToolbox/Metal operation and HDR readbacks. Debug packaging, release compilation,
and the existing development signature were verified. GPU/presentation joins and
independent GPU windows are bounded to 1,024 scalar records, preserve callback
order independence, and do not retain frames/drawables until presentation.
No decoder replacement, software fallback, or private presentation API was added.
