# Stream latency debugging

The macOS debug build exposes **Frame pacing**, **VSync**, and **Drawable buffers**
in Settings. Reconnect after changing them. Schema 5 exports record the requested
settings and `presentationRuntime`, which captures the actual layer/display policy
for the connected surface. Use the latter when comparing runs. The default is
**On decoded frame**, VSync off, and three drawable buffers. Explicit saved settings
remain respected. VSync off can tear; macOS can still delay presentation.
The historical baseline below was display paced with VSync on. See the
[continued GPU/HDR investigation](latency-optimization-2026-09-13.md) for newer results.
The [Metal statistics comparison](statistics-metal-overlay-2026-09-13.md) records
the panel now drawn into the video pass, its accessibility support, and the
controlled hidden/SwiftUI/Metal/hidden results. Those results do not establish
a latency improvement or Direct presentation.

## Initial measured baseline

The September 13, 2026 export requested 3440 × 1440 at 165 FPS, HEVC HDR10,
350 Mbps. Around the supplied screenshot, snapshots show 164.6–165.0 received FPS,
16.86–17.01 ms recent mean first-packet → presentation, and about 2.00 ms recent
mean VideoToolbox decode time. The simple overlay's 18.16 ms is a latest-frame
sample held for up to five seconds; it is not a mean.

The final 1,024 distinct presentations averaged 22.265 ms, with p95 28.621 ms.
Their intervals were multiples of approximately 6.06094 ms (165 Hz): 710 intervals
of one refresh, 277 of two, 32 of three, and four of four. GPU execution averaged
0.983 ms in its separate recent window. The decoder emitted all 22,243 acquired
frames without failure; 2,467 outputs (11.09%) were replaced in the latest-frame
mailbox before selection. Mailbox high-water was one and GPU in-flight high-water
was two. These facts support investigating presentation scheduling; they do not
prove a specific count of queued display frames.

The final presentation window ends earlier than the decoder window around
teardown. The export has no calibrated stage breakdown. Do not subtract its
decoder/GPU averages from the presentation average, or subtract raw decoder
timestamps from Core Animation timestamps. A GPU command becoming complete also
does not mean its drawable has appeared on screen.

## Live debug findings, September 13

Six debug connections recorded 3440 × 1440 HEVC HDR10 at 165 Hz, requested
350 Mbps, native full screen, and approximately 165 received FPS. The detailed
statistics overlay was visible in all six runs. Connection durations including
setup ranged from 48.5 to 86.9 seconds. Each result
below uses the final 1,024 confirmed distinct presentation records. Capture links
refer to local investigation artifacts, which are ignored by Git.

| Run / capture | Actual pacing / VSync / drawables | Final mean | Final p95 | Rolling means at 20–45 s: min / median / max |
|---|---|---:|---:|---:|
| A [D3A65082](../../artifacts/latency-investigation-2026-09-13/stream-1789278067569-D3A65082.json) | Display link / on / 3 | 22.904 ms | 23.877 ms | 21.329 / 22.631 / 23.059 ms |
| B [AEFEF676](../../artifacts/latency-investigation-2026-09-13/stream-1789278171664-AEFEF676.json) | Immediate / on / 3 | 19.588 ms | 24.275 ms | 17.421 / 18.479 / 19.837 ms |
| C [A5DF3A08](../../artifacts/latency-investigation-2026-09-13/stream-1789278245964-A5DF3A08.json) | Immediate / off / 3 | 9.333 ms | 14.064 ms | 9.017 / 10.890 / 14.410 ms |
| D [14CA8FE4](../../artifacts/latency-investigation-2026-09-13/stream-1789278333211-14CA8FE4.json) | Immediate / off / 2 | 13.948 ms | 21.753 ms | 9.764 / 10.013 / 10.428 ms |
| A2 [08ED9371](../../artifacts/latency-investigation-2026-09-13/stream-1789278446738-08ED9371.json) | Display link / on / 3 | 23.495 ms | 24.315 ms | 20.914 / 21.634 / 22.577 ms |
| C2 [C704CE71](../../artifacts/latency-investigation-2026-09-13/stream-1789278569737-C704CE71.json) | Immediate / off / 3 | 16.859 ms | 17.949 ms | 14.453 / 15.040 / 15.498 ms |

The last column describes overlapping timeline snapshots whose individual means
cover recent 1,024-frame windows. Its median is a median of rolling means, not
a per-frame median or whole-session average. The final presentation window also
covers only the end of each connection. The baseline repeat remains near 23 ms
at the end. Immediate/unsynced presentation lowers the final mean in both
comparisons, but the repeated C2 run does not sustain a sub-15 ms result. These
results support investigating presentation policy for this workload; they do not
establish a universal latency or a universal drawable-buffer winner. These six
runs did not isolate overlay visibility; the later [dedicated statistics
comparison](statistics-metal-overlay-2026-09-13.md) records hidden and visible cases
with its own measurement limits. A seventh exploratory run started with the
overlay visible, hid it through the shortcut, and
later showed it again. Its mixed visibility excludes it from conclusions about
the overlay; `comparison-context.json` records that limitation separately.

Run A's complete same-frame path identifies the dominant delay:

| Paired stage | Mean |
|---|---:|
| First packet → decoder callback | 2.607 ms |
| Decoder callback → render start | 2.723 ms |
| CPU rendering → commit | 0.229 ms |
| Commit → confirmed presentation | 17.344 ms |
| Total first packet → confirmed presentation | 22.904 ms |

All 1,024 records have complete coarse and detailed paths, and their stage sums
match their total to floating-point precision. CPU commit preceded the
display-link submission deadline on every record: 5.698 ms early on average,
at least 4.424 ms early. The target presentation timestamp followed that deadline
by 6.061 ms. Commit → presentation therefore consists of 11.759 ms until the
target plus 5.585 ms after the target. In 934 of 1,024 frames, presentation
followed the target by more than 5 ms; most delays were approximately one 165 Hz
refresh. The measured bottleneck is presentation scheduling, with no CPU
submission-deadline misses in this population. A2 similarly averages 17.608 ms
from commit to presentation.

Run D is mixed. It is steady around 10 ms through much of the run, then a
transient around 52–55 seconds raises its final mean. Chronological 256-frame
quarters of its final window average 10.895, 19.384, 15.440, and 10.072 ms:
performance recovers before disconnect. Its final-window drawable acquisition
waits are longer (quarter means 0.436–1.192 ms, versus approximately 0.03 ms in C),
but its 20–45 second rolling means are steadier than C's. The final 13.948 versus
9.333 ms comparison alone does not prove two buffers consistently worsen latency.
The transient is visible in streaming snapshots, so it cannot be dismissed as
only a final teardown measurement. These six new final presentation windows end
within one to five frame IDs of decoder completion; they do not have the large
frozen-renderer gap present in the original export.

C2 shows substantial variation despite the unchanged immediate/unsynced/three
drawable policy: its rolling means are 14.453–15.498 ms at 20–45 seconds,
6.584–12.023 ms at 65–80 seconds, and 13.985–16.933 ms after 80 seconds.
The final paired path is 2.359 ms first packet → callback, 0.282 ms callback →
render start, 0.248 ms CPU → commit, and 13.969 ms commit → presentation, totaling
16.859 ms. C1's corresponding commit → presentation mean is 6.576 ms.
Nearly all of the difference between these final windows occurs after commit;
decoder time and drawable acquisition remain small. C2's final chronological
quarters average 15.716, 16.944, 17.533, and 17.242 ms, so its result is not an
isolated stop-time outlier. The data does not yet identify the cause of this
post-commit variation.

Presentation confirmation also differs by policy. C1 records 560 unconfirmed
presentation callbacks from 8,301 submissions (6.75%), and C2 records 567 from
13,559 (4.18%). D records three from 8,649, while A/B/A2 record 28/2/48.
Unconfirmed callbacks do not contribute latency samples and are not network
losses. Final confirmed presentation cadence is 143.88 FPS for C1, 157.30 for C2,
and 158.00 for D. Account for this population difference when evaluating lower
latency, rather than assuming every received frame has confirmed display timing.

## Automatic local debug captures

`DEBUG` builds automatically write each finalized connection report to
`NSTemporaryDirectory()/SwiftlightLatency/stream-<timestamp>-<random>.json`.
On the investigation Mac this directory is
`/var/folders/pr/j864tssj37x7r_fdy1hs0dhr0000gn/T/SwiftlightLatency/`.
The timestamp in the filename is Unix time in milliseconds; the random suffix
distinguishes captures. These are local temporary files and can be removed by
the OS. Copy useful captures into the investigation directory before relying on
their retention. Normal live and last-stream menu exports remain available.

## Controlled sequence

To isolate the statistics panel in a `DEBUG` build, select a computer with a
Desktop app and choose **Stream → Run Statistics Overlay Comparison**. It
reconnects for four cases and exports live snapshots at 10, 20, and 30 seconds
to `~/Library/Application Support/Swiftlight/LatencyExperiments/`. Keep the
scene, display, full-screen state, and input capture fixed. See the
[comparison procedure and limits](statistics-metal-overlay-2026-09-13.md#repeat-the-comparison).

Keep the display, full-screen state, host scene, resolution, FPS, codec, HDR,
bitrate, and network path unchanged. Use a repeatable moving scene that sustains
the requested incoming FPS. Warm up each connection and export a live snapshot
after the same duration, while streaming, before disconnecting. Exported frame
windows contain at most 1,024 recent samples, not the entire run.

| Run | Frame pacing | VSync | Drawable buffers | Comparison |
|---|---|---|---:|---|
| A | Display paced (baseline) | On | 3 | Original policy with stage diagnostics |
| B | On decoded frame | On | 3 | A → B isolates the scheduling policy |
| C | On decoded frame | Off | 3 | B → C isolates the layer VSync setting |
| D | On decoded frame | Off | 2 | C → D isolates drawable pool size |

Repeat A after D to check drift, and repeat any apparent winner. Save exports
with distinct names such as `A-baseline.json` and `B-immediate-vsync.json`.
Choose from repeatable mean/tail latency, confirmed presentation rate, frame
replacement counts, image correctness, and tearing tolerance. A lower mean alone
does not establish an improvement if the workload or presented-frame population
changed. These comparisons are a sequence of controlled changes, not a complete
factorial test of interactions.

## Analyze exports

```sh
python3 scripts/analyze-stream-latency.py \
  /path/to/A-baseline.json /path/to/B-immediate-vsync.json \
  /path/to/C-immediate-unsynced.json /path/to/D-two-drawables.json \
  --output artifacts/latency-comparison.json
```

The script prints each metric's count, mean, p50, p95, p99, minimum, maximum,
and missing/invalid counts. JSON also contains the requested and actual settings,
session counters, presentation cadence, calibration uncertainty, and complete
same-frame paths. Percentiles use linear interpolation at `(n - 1) × p`.
It accepts older schema 3 exports and reports unavailable stages explicitly.

Use the **matched coarse path** to compare additive costs on one population:
first packet → decoder callback → render start → commit → presentation.
The **matched detailed path** additionally separates complete-frame enqueue,
decoder admission, VT submission, and mailbox selection. `sumMinusTotalMilliseconds`
should be near zero for complete paths. Missing stage data is not replaced with
zero, and independent decoder/GPU windows remain separate.

`deadlineToCommitMilliseconds` and
`targetPresentationToPresentationMilliseconds` are signed. Positive values mean
commit followed the display-link deadline or presentation followed its target.
These fields are naturally absent for the immediate path. Drawable acquisition
is reported separately where measured; do not add it again if it overlaps a
stage in a matched path. The cadence reference uses exported display refresh
when available; otherwise it is explicitly inferred from the p10 interval and
may represent a multiple of the panel's actual refresh period.

Confirmed drawable presentation is an OS-reported event, not physical scanout.
The measured reductions above apply to these debug runs and their recorded
populations. Validate any selected policy on the user's moving game scene and
display before treating it as a general default.
