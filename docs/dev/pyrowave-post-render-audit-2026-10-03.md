# PyroWave post-render timing audit — October 3, 2026

The higher post-render interval is present in the operating system's recorded
GPU-end and drawable-presentation timestamps. It is not created by subtracting
decoder averages, native decoder clock calibration, or delayed CPU callbacks.
The evidence locates the additional interval after the render GPU completes;
it does not establish that removing Swiftlight's codec validation caused a
presentation regression.

## Published source

The implementation was committed and published on the existing feature branches:

- Swiftlight `codex/pyrowave`: `abba37f137649280ddb88b0bd426a74e97b91b20`.
- Apple decoder `codex/pyrowave`: `dd295065417344a0a5d3d240bce9060d2646851c`.
- Its PyroWave dependency `codex/apple-decoder-integration`:
  `488564aa2b5ffca0377938c27a1b67fce817c5b9`.
- The direct Swiftlight PyroWave dependency was already published on
  `codex/metal-improvements`: `56b007143b471def3e41d5e74d10f73dfc8c8df1`.

Remote branch heads were verified. Swiftlight's HEVC/AV1 package pin remains
unchanged; the direct PyroWave gitlink and `Dependencies/versions.json` agree.
Unrelated editor, plist, local Xcode configuration and Moonlight Qt edits were
preserved outside these commits.

## What the interval measures

`MetalVideoRenderer` computes the same-submission interval as:

```text
GPU end → presentation = (drawable.presentedTime − commandBuffer.gpuEndTime) × 1000
```

Apple documents [GPU end time](https://developer.apple.com/documentation/metal/mtlcommandbuffer/gpuendtime)
as a host-clock timestamp relative to system Mach time, read after command
completion. [Drawable presented time](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime)
records the host time of presentation, with zero when no usable presentation
occurred. Both endpoints of this interval use that host-clock domain; conversion
from the native decoder's uptime clock is not involved.

The renderer registers both handlers before committing, joins them by submission
identity in either callback order, and retains the earliest confirmed presentation
of a distinct decoded frame together with that submission's GPU timestamps.
Zero/nonfinite presentation timestamps remain unconfirmed and are excluded.
The CPU completion and presented-handler arrival times are separate fields.

The immediate path already uses [`commandBuffer.present(drawable)`](https://developer.apple.com/documentation/metal/mtlcommandbuffer/present(_:)),
which requests presentation as early as possible after scheduling. There is no
client-requested presentation time or minimum duration on that path. VSync off
does not guarantee that the operating system will present immediately.

The first-packet → presentation interval separately calibrates native uptime to
the host clock. All 1,024 frames in each analyzed window had a complete additive
path. The recorded calibration bracket was at most 21 ns in the two original
captures and 42 ns in the repeat. These are sampling-precision bounds, not a
measurement of Apple's timestamp accuracy against physical panel scanout.

## Original Release windows

The retained old-validator capture and the new native-validation capture used
the same recorded runtime policy: 3440 × 1440 PyroWave HDR10 4:4:4, requested
165 FPS, immediate pacing, VSync off, three drawables, native full screen,
linear-sRGB `rgba16Float`, child Metal layer, per-frame EDR metadata, and the
statistics bitmap visible. Each row below uses the same 1,024 confirmed distinct
frames within its capture; these are recent windows, not whole-session means.

| Same-frame metric | Earlier Release | Native validation Release |
| --- | ---: | ---: |
| Decode callback → render start, mean | 0.037 ms | 0.061 ms |
| Render CPU → commit, mean | 0.034 ms | 0.037 ms |
| Commit → render GPU start, mean | 0.151 ms | 0.156 ms |
| Render GPU execution, mean | 0.978 ms | 0.983 ms |
| Render GPU end → presentation, mean | **0.313 ms** | **3.001 ms** |
| Render GPU end → presentation, p95 | 0.457 ms | 6.820 ms |
| GPU end → CPU completion callback, mean | 0.212 ms | 0.175 ms |
| Presentation → CPU presented callback, mean | 2.035 ms | 2.470 ms |
| First packet → presentation, mean | 13.097 ms | 14.445 ms |
| Confirmed presentation cadence | 146.604 FPS | 140.695 FPS |

The additional post-GPU interval averages **2.688 ms**, while GPU rendering
itself is essentially unchanged. Recomputing the interval directly from the
exported raw endpoints reproduces these means. GPU in-flight high-water is one
and no render submissions were skipped for GPU capacity in either session.
Pending-presentation high-water is two versus four: GPU work completion does not
mean the display has retired that drawable.

The new window's post-GPU quarter means are 2.954 / 3.100 / 3.061 / 2.891 ms.
The increase is present throughout the recent window. Its correlation with
first-packet latency is 0.905; correlation with render GPU execution is −0.023.
The change is consistent with presentation scheduling, composition or different
arrival phase relative to refresh. No compositor mode change was recorded in
these two captures, so none is claimed. Finishing GPU work earlier can also
increase this residual interval without moving the eventual display timestamp.

The sessions were recorded about 43 minutes apart, with different delivered
cadences. They are not a controlled causal A/B. Neither the residual interval
nor its change should be subtracted from end-to-end results to manufacture a
lower latency number.

## Unchanged-build repeat

A further uninstrumented session used the same signed Xcode Release binary and
saved stream settings, then disconnected locally. It lasted 246.149 seconds.
The Release executable's SHA-256 was
`c1041abcb5cd77c48e8a3af5f0491cf23796bc7187504994b42bb00a238835a7`.
The host content changed during this investigation; the final 1,024-frame window
spans 63.876 seconds at **16.015 FPS**, so it is excluded from the matched
high-cadence performance comparison.

Its post-GPU presentation wait averages **9.849 ms**, with p95 **14.554 ms**;
render GPU execution averages 1.378 ms. Render-start, GPU-completion and
presentation cadence all agree near 16.015 FPS. Every presentation identity
joins to GPU completion, frame IDs are consecutive, and there are no join
evictions or duplicate identities. This is a low-cadence rendering workload,
not a 165 FPS render workload with most timing callbacks missing.

99.71% of presentation intervals fall within 25 µs of a multiple of the exported
6.060916 ms refresh interval, chiefly ten or eleven refreshes. This demonstrates
a refresh-aligned presentation regime in that window. It does not prove the
same regime explains the original 3.001 ms result. The wait varies across four
quarters rather than growing monotonically.

## Separate Metal trace

A separate session recorded a 20-second `Metal System Trace` attached to the
same Release process. Its accompanying stream export covers 138.392 seconds;
the trace and export windows are not interchangeable. Profiling and trace
finalization perturb the machine, and the content/cadence differ from the two
original Release runs. This session is excluded from acceptance timing.

The trace recorded 351 client drawable-present requests. Its displayed-surface
interval table explicitly attributes 323 intervals to Swiftlight and marks
their direct-to-display eligibility false. The recorded failure is that the
layer geometry is not defined in screen space. The table's narrative relates
the compositor output surface to the Swiftlight frame and source surface, so
this attribution does not rely on matching unrelated numeric surface IDs.
These are 323 distinct Instruments frame IDs, not transport frame IDs.

This is concrete evidence that those traced Swiftlight frames used composition
and a useful reason to inspect the layer hierarchy. Release currently hosts the
Metal layer below the AppKit view's backing layer; the existing root Metal layer
experiment is Debug-only. The trace's generic suggestion to check rasterization
is not proof that Swiftlight enabled rasterization: source contains no
`shouldRasterize` assignment, and ancestor layer state was not inspected.

Display association also remains unresolved: device metadata includes the
3440 × 1440 external display at a maximum 165 Hz, matching the app's runtime
policy, but the displayed-surface table labels the attributed rows with the
built-in display's name and resolution. Its connection UUID changes per interval.
Those labels do not establish which physical screen displayed these frames, so
the trace is not used to claim a physical-display cadence or move between screens.

The trace cannot prove a direct-to-composited transition between the original
0.313 and 3.001 ms captures, which have no corresponding traces. Nor can global
display-swap delays be assigned to Swiftlight's GPU-end interval without joining
that exact application's submission. Preserve this evidence as a presentation
eligibility finding, not a measured improvement from an untested layer change.

## Comparison endpoints and next measurements

The local Moonlight Qt native Metal path does not expose the same endpoint.
`pacer.cpp` measures CPU duration around `renderFrame()` for its overlay's
rendering statistic. In immediate mode, `vt_metal.mm` presents, commits and waits
for GPU command completion before returning. In its display-link mode,
`renderFrame()` queues a frame and returns before later GPU submission. Neither
path records `drawable.presentedTime` in this checkout. Qt's decode average also
includes queue time starting at complete-frame enqueue; Swiftlight's PyroWave
admission interval and HEVC/AV1 VT-submit interval have different scopes.

Compare equivalent endpoints across clients: first-packet receipt through
confirmed drawable presentation, complete-frame enqueue through decoder output,
render GPU start through GPU end, and GPU end through confirmed presentation.
Use the same frame identities, workload, measured cadence, display mode, HDR
policy and warmup, and include missing/unconfirmed samples and presentation
cadence. CPU callback delivery is useful scheduling telemetry, but is not the
presentation event. Other clients need their own endpoint audit or matching
instrumentation before overlay numbers can be compared.

To identify the cause of the residual wait, alternate matched high-cadence runs
of the same binary and moving scene, recording a separate diagnostic Metal trace
for display queue/swap/composition evidence. Then vary one renderer policy at a
time: drawable count, child versus root Metal layer, or EDR metadata updates.
Keep profiler runs separate from acceptance timing, restore settings, and reject
an apparent latency improvement that reduces cadence. Physical display or
input-to-photon comparisons require a shared external optical measurement;
confirmed drawable presentation alone does not establish those endpoints.

## Evidence and checks

Raw exports and profiling data remain local under ignored
`artifacts/pyrowave-native-validation-2026-10-03/`; no raw trace was published.
The earlier export is retained separately under
`artifacts/pyrowave-latency-2026-10-03/`.

| Export | SHA-256 |
| --- | --- |
| `retained-release-run.json` | `104bab7324f81e522e55de630b28e12e24942cd7df49a1d54fd6c6f293cdece2` |
| `live-release.json` | `bb7ba2a8838a40d249695cee0f1282a2df94e97fc80d4b2c60987109d14153f0` |
| `post-render-repeat-1.json` | `c9969ceda8b6e34533453356cacd0dcb80468b216870ff019c51f8e59911b667` |
| `post-render-profiled.json` | `6d5a1a8588c66f0d5b6ce628e60e4068df480eb6bbc44fdd77545be292fe040e` |

`scripts/analyze-stream-latency.py` analyzed the exports. All 17 focused
`TimingStatisticsTests` passed in this audit, including deliberately delayed and
reversed callback delivery, invalid timestamps, bounded missing callbacks and
redraw identity pairing. No renderer timing code was changed. Full implementation
gates and the earlier live build are recorded in the
[native validation handoff](pyrowave-native-validation-2026-10-03.md).
