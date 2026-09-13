# Stream diagnostic exports

Choose **Stream → Export Last Stream Diagnostics…** after a connection attempt
ends, or use the same action in the library's computer-options menu. The action
is disabled until there is a retained report. The native save panel writes JSON
atomically to the selected location. Canceling the panel keeps the report available.
The existing live stream-options action still exports a current snapshot.

One completed report is retained **in memory for this app run**. Starting another
connection leaves the previous report available until the new attempt ends. An
unsuccessful connection also replaces it, with unavailable media fields omitted.
Disconnect, transport failure, network loss and suspension all finalize a report.
Release builds require exporting before quitting. Debug builds also save each
completed report in `NSTemporaryDirectory()/SwiftlightLatency/`; the operating
system may clear this temporary directory. A failed automatic write preserves
the normal in-memory report. A crash or forced termination cannot finalize a
report. No report is uploaded automatically.

## Schema 5

- App/OS versions, export capture time, connection settings, requested/decoded
  format strings, thermal state, terminal phase and safe failure category/code.
- Timeline start/end dates, monotonic elapsed duration and at most 600 recent
  samples. Samples contain stream statistics and phase, at most once per second
  plus an unconditional terminal sample. `discardedSamples` identifies truncation.
- Final decoder and renderer counters and bounded timing arrays.
- Build configuration and actual presentation runtime: pacing, VSync, drawable
  count, refresh rate, full-screen state, layer opacity, drawable dimensions,
  output color space and pixel format. Screen refresh intervals and update
  granularity support comparisons on fixed and variable refresh displays.
- Actual statistics-overlay visibility and input capture, requested rendering
  options, and the number of layer HDR-metadata updates. Released input capture
  exposes stream controls over the video, even when the statistics panel is hidden.
- Paired packet, enqueue, admission, VT, frame selection, CPU submission, kernel
  scheduling, GPU execution and confirmed presentation stages, as described below.
- Network RTT/deviation, frame and compressed-byte counters, queue depths,
  audio queued/underrun/overrun counters, and the bound socket's interface name.

The renderer exports two independent populations:

| Field | Population and meaning |
| --- | --- |
| `completedFrameTimings` | Up to 1,024 completed render submissions, including unsuccessful commands, redraws and submissions without a confirmed presentation. Records success, CPU/kernel/GPU stages, first-packet → GPU-end and decoder-callback → GPU-end where clocks are valid. Contains no display timestamp. |
| `presentationTimings` | Up to 1,024 distinct decoded frames with a positive drawable `presentedTime` joined to command completion for that same render submission. Redraws retain the earliest confirmed presentation. Includes first-packet → presentation and GPU-end → presentation. |

Completion and presentation callbacks can arrive in either order. Their scalar
timing records are joined by submission identity without retaining media resources.
`pendingPresentation` counts submitted drawables awaiting a presentation callback;
`completedAwaitingPresentation` is the subset whose command-completion callback arrived.
`unconfirmedPresentation` counts callbacks without a usable positive timestamp.
The join is bounded to 1,024 submissions; `presentationTimingJoinEvictions` reports
discarded diagnostic entries, not dropped video frames. Independent completion
records remain available when presentation is unconfirmed or the join is evicted.

Use `completedFrameTimings` to inspect work through GPU completion when display
timestamps are unavailable. GPU completion cannot substitute for presentation.
Likewise, subtracting independent timing-window averages does not establish a
same-frame stage duration. Use the joined `presentationTimings` fields for that.

GPU start/end and Core Animation timestamps use system Mach time in seconds;
decoder timestamps are calibrated before crossing clock domains. GPU timestamps
are read after command completion. Scheduled/completed/presented callback times
describe CPU notification delivery, which may follow the underlying event.
Missing or invalid stages remain unavailable. Display-link deadline/target
deviations are signed. Commit → presentation includes GPU work and system delay;
GPU-end → presentation removes this command's GPU execution but still includes
system buffering, composition and display scheduling. It does not identify an
individual compositor operation or measure physical scanout. See
[latency debugging](stream-latency-debugging.md).

The snapshot is frozen before native owners are cleared. Pending decode, audio or
presentation callbacks may finish later and are not included. The timeline includes
connection setup in elapsed time and may have gaps when the main run loop is delayed
or asleep; it is not a per-frame trace. Timing summaries retain their existing recent
sample windows, rather than becoming whole-session averages. See [stream statistics](stream-statistics-implementation.md)
for definitions, clock calibration, and estimated host-to-display limitations.
Non-finite numeric values, if any, encode as `NaN`, `Infinity` or `-Infinity` strings
so even a rejected configuration can be exported as valid JSON.

The payload deliberately omits host/client addresses, saved host IDs, app names,
PINs, OTPs, certificates, private keys, input events, media and raw error user-info.
An interface name such as `utun8`, stream preferences, uptime and OS version remain
useful debugging context. Failure reporting uses a type/category and numeric code;
full arbitrary error messages are not copied into the export.

## Debug comparison captures

Debug builds expose **Stream → Run Latency Comparison (Short)** and **Run Latency
Comparison (Full)**, with **Cancel Latency Comparison** to stop. The runner uses
the selected computer's Desktop app, keeps the stream request constant, and applies
the named presentation variants in native full screen. It takes live snapshots at
10, 30 and 50 seconds after streaming begins. Each snapshot still contains bounded
recent timing windows; the interval between checkpoints is not a whole-run average.

Outputs go to `~/Library/Application Support/Swiftlight/LatencyExperiments/` with case,
checkpoint and actual statistics-visibility labels. The JSON records the actual
layer configuration and overlay state. Manual disconnects, settings or display
changes, and altered statistics visibility stop the sequence. The runner restores
the original settings and disconnects locally while leaving Desktop running on the
host. Comparison checkpoints persist locally; ordinary finalized debug reports remain temporary.

The production defaults are decoded-frame pacing, VSync off and three drawable
buffers. HDR ordering/caching and root-layer changes remain opt-in after measured throughput regressions.
Explicitly saved presentation settings are retained. The comparison runner also
has a debug-only native PQ experiment using `bgr10a2Unorm` and Rec.2100 PQ. It leaves
`edrMetadata` nil: Apple's non-nil metadata contract requires a linear output color
space with values above 1.0. Disabling metadata-driven tone mapping can change
highlight handling, so PQ remains an experiment. See Apple's
[EDR metadata requirements](https://developer.apple.com/documentation/quartzcore/cametallayer/edrmetadata).

## Validation

Deterministic tests cover timeline bounds, terminal freezing, failures before the
first frame, JSON encoding and invalid clocks. Timing tests cover same-frame stage
accounting, callback order, unconfirmed presentation and bounded diagnostic storage.
Hardware/offscreen completion establishes rendering behavior; live presentation
measurements and their limitations belong in the
[latency investigation](stream-latency-debugging.md).
