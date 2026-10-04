# Stream diagnostic exports

On macOS, choose **Stream → Export Last Stream Diagnostics…** after a connection attempt
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
  Requested and negotiated strings include chroma sampling; decoded strings
  include it only when identified from the actual output storage and plane geometry.
- Timeline start/end dates, monotonic elapsed duration and at most 600 recent
  samples. Samples contain stream statistics and phase, at most once per second
  plus an unconditional terminal sample. `discardedSamples` identifies truncation.
- Final decoder and renderer counters and bounded timing arrays.
- Optional `decodedColor` captures the latest decoded frame selected by the
  presentation surface: ISO primaries, transfer and matrix codes, full-range and
  color/range validity flags, and chroma location. `masteringDisplay` exists only
  for an exact 24-byte SMPTE ST 2086 payload, with semantic red/green/blue/white
  xy coordinates and minimum/maximum luminance in nits. `contentLight` exists
  only for an exact four-byte payload, with maximum content and frame-average
  light levels in nits. These bounded scalars are decoded at export/checkpoint
  time; no per-frame diagnostic work, media, raw byte arrays or frame identity
  is added. Missing metadata and fields omitted by older schema-5 reports remain
  unavailable. This snapshot does not prove HDR appearance or Direct presentation.
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
  `compressedStaleSkips` counts independently decodable PyroWave units replaced
  by newer queued units before decoder admission. It is local latency recovery,
  separate from network loss and decoded-frame mailbox replacement. Older reports
  omit this optional counter; its absence does not establish zero skips.

The decoder's additive `pyrowaveAdmissionToCallbackMilliseconds` array contains
at most 1,024 valid native admission → GPU completion callback durations from
successful PyroWave output frames. It includes CPU preparation, record parsing,
coefficient upload, Metal encoding, GPU scheduling/execution and completion
callback delivery, ending before rendering or presentation. Failed/cancelled/
dropped outputs and absent or reversed timestamps do not enter this population.
`singleSampleVTSubmitToCallbackMilliseconds` retains its VideoToolbox-only
submit → callback meaning for HEVC/AV1, excluding multi-sample aggregates and
show-existing events. `stream.decodeTime` and the shared panel row summarize the
active measured population; these scopes differ by codec and are not combined.
No valid samples means an unavailable summary, rather than measured zero. Older
schema-5 exports may omit the PyroWave array; absence is unavailable, not zero.

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
Optional `renderSubmissionID` identifies the same renderer submission in both
populations. `drawableID` is the public Metal drawable identifier, scoped to its
CAMetalLayer; zero is valid. Offscreen submissions omit it. Neither scalar is a
media pointer or a verified match to an Instruments surface/frame identifier.
An overlapping trace must establish that mapping before comparing endpoints.
Older reports omit both fields.

The join is bounded to 1,024 submissions; `presentationTimingJoinEvictions` reports
discarded diagnostic entries, not dropped video frames. Independent completion
records remain available when presentation is unconfirmed or the join is evicted.

Use `completedFrameTimings` to inspect work through GPU completion when display
timestamps are unavailable. GPU completion cannot substitute for presentation.
Likewise, subtracting independent timing-window averages does not establish a
same-frame stage duration. Use the joined `presentationTimings` fields for that.

Both populations also carry optional `transportStages` from that exact admitted
access unit. Its `payloadBytes` counts depacketized compressed bytes, excluding
RTP, FEC parity and tunnel overhead. `partialFrame` identifies units containing
synthesized loss placeholders; their byte count is not received wire bytes and
their last-required-packet timestamp remains unavailable. The optional raw
timestamps use the decoder's `CLOCK_UPTIME_RAW` domain:

- `firstPacketNanoseconds` → `lastRequiredPacketNanoseconds`: first accepted
  packet to the decisive accepted data/parity packet at userspace RTP entry.
  This includes delivery, receiver scheduling and earlier-block FEC work, and
  must not be called pure network transit or kernel-arrival time.
- `lastRequiredPacketNanoseconds` → `fecReadyNanoseconds`: final-block recovery
  and ordering until the complete frame is ready for depacketization.
- `fecReadyNanoseconds` → `enqueueNanoseconds`: whole-frame depacketization
  through the existing access-unit creation timestamp.
- `enqueueNanoseconds` → `queueOfferNanoseconds`: assembly finalization through
  the sample immediately before decode-queue offer.
- `queueOfferNanoseconds` → `handoffNanoseconds`: queue residence, pull-worker
  scheduling, validation and flattening until the Swift callback handoff.
- `handoffNanoseconds` → `admissionNanoseconds`: Swift byte/sideband acquisition
  and decoder-worker dispatch until native admission.

The corresponding `firstPacketToLastRequiredPacketMilliseconds`,
`lastRequiredPacketToFECReadyMilliseconds`, `fecReadyToEnqueueMilliseconds`,
`enqueueToQueueOfferMilliseconds`, `queueOfferToHandoffMilliseconds` and
`handoffToAdmissionMilliseconds` add to `firstPacketToAdmissionMilliseconds`
only on complete, valid records. Missing/zero, out-of-span or reversed stages
remain unavailable. Earlier schema-5 reports omit this object; their coarse
packet-to-availability measurement is unchanged. These bounded scalar additions
contain no media, addresses, packet contents or remote identities.

Both populations can include an optional `decodeStages` object from that decoded
frame's completion. This is an additive schema-5 field; older reports and native
producers can omit stages. It carries only scalar monotonic timestamps and
durations, alongside the enclosing frame/submission identity:

| Decode stage | Meaning |
| --- | --- |
| `admissionToPreparationStartMilliseconds`, `preparationMilliseconds` | Admission to input-preparation entry, then CPU outer-framing adaptation and input preparation for PyroWave, or package preparation for HEVC/AV1. PyroWave codec parsing belongs to the native backend stage below. |
| `preparationEndToBackendStartMilliseconds` | Preparation end to backend entry, including any first-frame configuration. |
| `backendPreparationMilliseconds` | Backend entry to its native call; PyroWave packet parsing/output acquisition, or VT sample construction. |
| `backendCallMilliseconds` | Native call CPU duration: PyroWave shared-buffer upload and Metal encoding, or VT DecodeFrame. This is not GPU execution. |
| `backendReturnToCallbackMilliseconds` | Native call return to decoder callback; an alternative coarse stage that overlaps the GPU detail below. |
| `backendReturnToGPUCommitMilliseconds`, `gpuCommitToStartMilliseconds`, `gpuExecutionMilliseconds`, `gpuEndToCallbackMilliseconds` | PyroWave encoding return to commit, GPU scheduling, GPU execution, then CPU completion dispatch. |
| `admissionToCallbackMilliseconds` | Same-frame total through the decoder callback, excluding later rendering/presentation. |

Optional `preparationStartNanoseconds`, `preparationEndNanoseconds`,
`backendStartNanoseconds`, `backendSubmitNanoseconds`, `backendReturnNanoseconds`,
`gpuCommitNanoseconds`, `gpuStartNanoseconds`, and `gpuEndNanoseconds` use the native
decoder monotonic clock. GPU start/end are read after completion and mapped into
that clock with a measured offset. `gpuClockUncertaintyNanoseconds` records that
mapping's sampling uncertainty. Missing validity flags, zero/reversed clocks,
timestamps outside the known admission/callback interval, and GPU calibration
uncertainty above one millisecond remain unavailable. Backend/GPU stages are
omitted for multi-sample aggregates and show-existing completions; preparation
can remain available. Existing VT-specific fields retain their VT-only meaning
and remain unavailable for PyroWave.

`decodeGPUEndToRenderStartMilliseconds` spans native GPU completion to render
entry for the same frame. Its optional
`decodeGPUToRenderCalibrationUncertaintyNanoseconds` sums native GPU clock-mapping
and renderer clock-calibration sampling uncertainty. This interval overlaps
decode GPU-end → callback plus callback → render entry; do not add all three.
Independent render-completion records also include optional packet → enqueue
and enqueue → admission stages, without adding a presentation timestamp.

The analyzer's `nativeDecode` and `nativeCPUDecode` matched paths compare detailed
and coarse decoder stages to that same frame's admission → callback total.
`nativeGPU` continues the detailed path through confirmed presentation;
`nativeGPUToRenderGPUEnd` ends at independent render GPU completion. Every stage
and total in a matched path uses the same complete records. Missing stages do not
borrow VT values or measurements from another population. The adapter uses the
size-aware native completion-copy/getter APIs so an older supported ABI-2 prefix
cannot expose an absent appended trace tail.

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
buffers. HDR metadata is cached and configured before drawable acquisition;
stable frames reuse the same tone-mapping state. A display-link update whose
metadata changes is deferred to the next supplied drawable. Legacy per-frame
metadata updates and acquisition ordering remain explicit debug comparisons;
root-layer changes remain opt-in. Matched live cadence and physical HDR brightness
must still be measured on the destination display.
Explicitly saved presentation settings are retained. The comparison runner also
has a debug-only native PQ experiment using `bgr10a2Unorm` and Rec.2100 PQ. It leaves
`edrMetadata` nil: Apple's non-nil metadata contract requires a linear output color
space with values above 1.0. Disabling metadata-driven tone mapping can change
highlight handling, so PQ remains an experiment. See Apple's
[EDR metadata requirements](https://developer.apple.com/documentation/quartzcore/cametallayer/edrmetadata).

## Mobile debug comparison captures

The mobile client has an explicit DEBUG-only capture path, without the Mac export
UI. It uses schema 5's shared settings, decoder, renderer, timing populations,
and safe stream fields. A `capture` object adds the trial label, random run ID,
checkpoint index, supplied source revision/tree hash, elapsed and stable-state
durations, warmup/exclusion counts, statistics preferences and visibility match,
device model/class, low-power state, and declared Game Mode support. Actual Game
Mode observation remains unavailable in the JSON and requires external evidence.
Mobile capture omits interface names and audio route identifiers.

Runtime fields without a supported mobile observation are optional and omitted,
including `displaySyncEnabled`, `displayRefreshHz`, refresh intervals, and update
granularity. Separate optional fields describe whether the display-sync control
is supported, the screen's maximum frame rate, and the display link's requested
frame-rate range. These are not measured presentation cadence.
`wantsExtendedDynamicRangeContent`, `edrMetadataConfigured`, and the owning display's
potential/current EDR headroom describe configuration when sampled on attachment,
layout, or an HDR transition; they do not measure luminance or physical scanout.
Mobile geometry also records optional `viewWidthPoints`, `viewHeightPoints`,
`viewContentScale`, `layerContentsScale`, `screenWidthPoints`, `screenHeightPoints`,
`screenScale`, `screenNativeScale`, `screenNativeWidthPixels`, and
`screenNativeHeightPixels`. These distinguish UIKit's logical backing size from
the panel's physical pixels and the actual drawable dimensions. Native screen
bounds retain their native orientation; orient them to the screen point bounds
before comparing width and height. Absent fields in older exports remain
unavailable. These scalar fields do not identify the host or include screen content.
Existing macOS field values and required timing meanings are unchanged.

Explicit mobile Debug captures may also include `presentationHierarchy`.
It records public scalar geometry and layer/view flags at most once per second,
using low-rate UI updates and the existing explicit capture checkpoints rather
than a new frame callback or timer. Checkpoints refresh even when hidden
statistics have stopped SwiftUI publication.
The snapshot timestamp makes its age observable. Traversal is bounded to 16 view
and 16 layer ancestors, 64 inspected sibling entries, eight potential-overlap
records, and 16 same-scene app windows, with truncation flags. Rectangles are
point-space bounding boxes; transforms and clipping flags must be considered
before interpreting coverage. An intersecting sibling can be transparent, so
`aboveSiblings` identifies candidates rather than proving visible overlap.
Same-level window order and system windows are not established by this snapshot.
No view/layer names, contents, text, or images are collected. Normal/Release
launches do not traverse the hierarchy, and older exports omit this field.

The capture retains at most three checkpoints per session and 32 files locally.
Ten seconds of warmup are excluded from the raw renderer arrays, including after
an observed visibility/control/input change. Other decoder/renderer summary
windows keep their independent populations. Details, opt-in flags, retrieval,
and comparison rules are in [mobile debug captures](stream-latency-debugging.md#mobile-debug-captures).

## Validation

Deterministic tests cover timeline bounds, terminal freezing, failures before the
first frame, JSON encoding and invalid clocks. Timing tests cover same-frame stage
accounting, callback order, unconfirmed presentation and bounded diagnostic storage.
Hardware/offscreen completion establishes rendering behavior; live presentation
measurements and their limitations belong in the
[latency investigation](stream-latency-debugging.md).
