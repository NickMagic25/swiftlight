# iPad presentation latency investigation

## Observed defect

The connected iPad Pro 11-inch (M5), running iPadOS 26.6.2, reported a logical
backing display of 2816 × 1940 pixels at a point scale of 2, but a physical display
of 2420 × 1668 pixels. `MobileStreamSurface` sized its Metal drawable with the
UIKit trait display scale, while the native stream request used the screen's
physical dimensions. This rendered 35.3% more pixels than the panel contains,
then required scaling to the panel. It also differed from Apple's prescribed
native-scale setup for a custom UIView backed by CAMetalLayer.

This establishes a geometry defect. It does not by itself establish the cause
of every composited frame or quantify the user's reported 20+ ms Present Delay.

## Correction

The mobile surface now uses its owning screen's `nativeScale` for the view and
Metal layer. A full-screen drawable uses the exact oriented `nativeBounds`
dimensions; this avoids a one-pixel mismatch when a fractional native scale and
rounded point dimensions disagree. Resized windows use native scale with whole
pixel dimensions. Geometry is checked before drawable acquisition and after
layout/attachment. A display-link drawable acquired before a geometry change is
discarded so the next update uses the corrected size.

Statistics rasterization uses the same native scale, preserving its point size
and accessible text geometry. Absolute touch coordinates are converted to
drawable pixels before applying the shared viewport transform, keeping integer
scaling and letterboxes aligned with the renderer. The decoder, HDR color path,
stream request, frame-pacing preference and drawable-count preference are
unchanged for this first comparison.

The reusable sizing and input conversion live in shared Core; only the UIKit
screen/view adapter changes on mobile. New optional runtime geometry fields
make logical scale, physical dimensions and actual drawable size distinguishable
in diagnostic exports. See the [export schema](diagnostic-exports-schema.md).

Both native adapters also contain each acquisition/render/commit operation in
an explicit autorelease pool, following Apple's drawable-lifetime guidance.
This releases temporary Objective-C/Metal references after CPU submission
instead of waiting for an outer UI run-loop pool. Display-link callbacks still
use their supplied drawable. The retained decoded frame and GPU `TextureLease`
ownership are unchanged, as are command-buffer presentation ordering and pacing.
The pool is a resource-lifetime correction; its latency effect is measured
separately rather than assumed.

## Metal HUD and platform differences

Apple describes Direct as the presentation path with the least buffering.
Compositing can add buffering when system UI or application layers overlap the
display. Direct is selected by the system; there is no public force-Direct switch.
A correctly sized opaque surface improves eligibility, without overriding system
windowing or promising Direct in a resized window or while controls are visible.

The source audit found an opaque black UIView with a root CAMetalLayer,
`framebufferOnly = true`, and `presentsWithTransaction = false`. There are no
explicit masks, rounded corners, shadows, rasterization or transforms on the
stream surface. Status-bar and persistent-system-overlay hiding are requested.
The connection spinner disappears after video begins; stream controls overlap
only while opened. Statistics are already in the same Metal drawable, with
separate nonvisual accessibility elements. The SwiftUI hosting ancestors and
actual on-screen coverage still require runtime inspection; a full-screen-cover
declaration and an opaque leaf do not establish that every ancestor is eligible.

`presentsWithTransaction = false` allows presentation independently of Core
Animation transactions. It does not disable composition. System notifications,
windowing and other overlapping UI can still change the selected path.

HUD Present Delay measures presentation-to-display delay, separately from GPU
execution and the earlier network/decode stages. Its rolling population is not
identical to Swiftlight's bounded first-packet-to-presentation population. Compare
same-frame stages instead of subtracting those independent averages.

The Mac's `CAMetalLayer.displaySyncEnabled = false` cannot be applied to iOS:
the installed iPhoneOS SDK marks it unavailable. Mobile's display-link path
already requests the lowest supported `preferredFrameLatency`, 1; this is a
request, not a guarantee of one physical refresh interval. Actual cadence and
post-GPU presentation timing need device measurement.

## Validation and measurement record

The original source at `21120eb912ccd93a604a44d19e8209d8a0f16740`, signed build and
test bundle are preserved under `artifacts/ipad-latency-2026-09-14/`, with source
and binary hashes. The initial baseline trial skipped because no Running tile
was found, and a second attempt failed device test authorization. Neither
produced timing samples. A later retry resumed the running application and
provided the first valid baseline.

The candidate device build-for-testing, Mac build, iPhone/iPad simulator build,
full `scripts/validate-ci.sh` gate and six focused geometry tests passed.
The tests cover exact full-screen portrait/landscape dimensions, fractional
scales, partial windows, invalid observations, integer letterboxing and fit/fill
touch-coordinate preservation. Build and test logs are tracked in the same
artifact directory.

Initial exploratory trials retained the 2420 × 1668, 120 Hz, 90 Mbps HEVC HDR
request and 7.1 System Spatial Audio. The table uses each trial's final checkpoint
and its own 1024 confirmed, joined frame records. These are individual trials,
not repeated-condition estimates or physical scanout measurements.

| Trial | Drawable / pacing / buffers | Distinct presentations/s | First packet → presentation mean / p95 | Commit → presentation mean |
| --- | --- | ---: | ---: | ---: |
| `baseline-off-3` | 2816 × 1940 / immediate / 3 | 120.00 | 33.708 / 34.858 ms | 24.890 ms |
| `candidate-off-1` | Native / immediate / 3 | 118.95 | 32.650 / 33.801 ms | 24.787 ms |
| `baseline-on-1` | 2816 × 1940 / immediate / 3 | 104.65 | 29.056 / 31.019 ms | 23.991 ms |
| `candidate-off-2` | Native / immediate / 2 | 60.00 | 25.811 / 26.712 ms | 16.645 ms |
| `candidate-off-3` | Native / display link / 3 | 104.39 | 23.330 / 24.220 ms | 16.300 ms |
| `candidate-off-5` | Native / display link / 2 | 93.92 | 24.980 / 28.666 ms | 16.262 ms |

All of these still reported Composited. The first native-size trial also had a
system notification in its end screenshot, so its roughly 1 ms lower average is
not a controlled improvement claim. The two-buffer immediate trial reduced
delay but halved presentation cadence: it is not an acceptable 120 Hz fix.
The overlay-on and display-link trials also lost cadence and need further
qualification before interpreting their lower averages. The baseline's matched
GPU path measured 22.688 ms between GPU end and confirmed presentation, locating
most of its delay after rendering rather than in video decoding.

Checkpoint deltas confirm approximately 120 received frames/s and no decoder
drops in these trials. Display-link/3 replaces more decoded mailbox frames
before selection. Immediate/2 also selects a frame before waiting for a drawable
and can replace it with newer output after acquisition: `takenForPresentation`
therefore is not the same counter as actual GPU submissions or presentations.
The host browser's stutter warning alone does not explain the client's lower
presentation cadence.
The first display-link/2 attempt (`candidate-off-4`) ended before warmup with
eight decoded frames and no confirmed presentation. The pre-teardown UI reports
an audio-route-change disconnect, not a renderer failure or latency sample.
Its bounded repeat succeeded but still lost
client presentation cadence; the test verified restoration of the original
settings after both attempts.

The continued comparison requires an unchanged host scene, request, HUD state, audio
route, brightness and display mode. Use the preserved baseline and candidate for
three statistics-hidden and three statistics-visible trials each, with the
existing 20/30/40-second checkpoints and stable-state warmup. Analyze each trial's
confirmed presentation cadence, same-frame first-packet-to-presentation stages,
tails and missing/unconfirmed counts. Overlapping checkpoint windows must not be
concatenated as independent samples. Record the HUD's actual Direct/Composited
state separately. No Direct-mode fix or production pacing change is established.

An additional Debug-only experiment reuses the existing shared native-PQ renderer
with `bgr10a2Unorm` / ITU-R 2100 PQ. It requires a valid explicit latency capture
and `SWIFTLIGHT_LATENCY_NATIVE_PQ=1`; normal and Release launches retain the
validated float16 linear output. The experiment preserves HDR10 mastering and
content-light metadata, using Apple's documented 10,000 scale for normalized
PQ output. It does not disable HDR or remove metadata to improve a HUD label.
The existing PQ overlay-blending approximation remains an experimental
limitation; color, tone mapping and physical presentation need separate checks.
The hardware/offline gate passed, including the existing native-PQ and overlay
readback tests. This verifies the shared shader's numerical output on the Mac;
it does not establish iPad HDR luminance or Direct presentation. Final Mac and
iPhone/iPad simulator app builds with the diagnostic experiment also passed.

The initial same-binary format pair (`candidate-off-6` linear,
`candidate-off-7` PQ) retained immediate pacing, three buffers and the same HDR
request/audio. Both remained Composited. Linear measured 25.292 / 27.131 ms
first-packet mean / p95 and 119.42 presentations/s; PQ measured 28.019 / 34.513 ms
and 117.36 presentations/s. This pair provides no reason to promote PQ. Its
hierarchy snapshot was approximately 40 seconds old because hidden statistics
stop SwiftUI publication, so it is not settled-hierarchy evidence. Subsequent
diagnostic builds refresh through the existing explicit capture checkpoints on
MainActor, with a weak surface reference and no new timer or media callback.
The first such attempt (`candidate-off-8`) also disconnected on an audio-route
change before warmup and is excluded from timing acceptance.

The variation between linear control runs also means output format alone does
not explain every additional refresh interval. Preserve per-run cadence and
tails instead of declaring a fixed improvement from one run's lower average.

A fresh subsequent capture (`candidate-off-9`) confirmed exact screen/window
coverage, no masks/corners/shadows/filters/rasterization or transforms in the
eight-layer ancestor chain, and no potential above-sibling overlaps. One higher
app window intersected the surface; that count does not prove visible pixels or
identify system UI. All snapshots were under 5 ms old. The run still reported
Composited and approximately 120 presentations/s, with 32.724 / 33.857 ms
first-packet mean / p95 and 24.833 ms commit-to-presentation mean.

## Apple guidance consulted

Consulted September 14, 2026:

- [Native screen scale for Metal](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/NativeScreenScale.html)
  and [QA1909](https://developer.apple.com/library/archive/qa/qa1909/_index.html):
  exact physical drawable dimensions and native view/layer scale avoid an extra
  sampling stage.
- [Metal Performance HUD](https://developer.apple.com/videos/play/tech-talks/110339/)
  and [HUD metrics](https://developer.apple.com/documentation/xcode/understanding-metal-performance-hud-metrics):
  presentation paths and metric meanings.
- [CAMetalDisplayLink](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink)
  and its [preferred frame latency](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/preferredframelatency):
  scheduling requests and limits.
- [Core Animation transaction presentation](https://developer.apple.com/documentation/quartzcore/cametallayer/presentswithtransaction)
  and [home-indicator hiding](https://developer.apple.com/documentation/uikit/uiviewcontroller/prefershomeindicatorautohidden):
  these preferences do not provide exclusive display ownership.
- [HDR output color spaces](https://developer.apple.com/documentation/metal/using-color-spaces-to-display-hdr-content)
  and the installed iPhoneOS SDK's `CAEDRMetadata.h`: packed PQ output and
  metadata optical-output scale.
- [Drawable lifetime](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/Drawables.html)
  and [CAMetalLayer](https://developer.apple.com/documentation/quartzcore/cametallayer):
  acquire late, release promptly, and contain a custom render loop in an
  autorelease pool while preserving command-buffer presentation ordering.
- [Designing for iPadOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ipados):
  preserve touch, orientation and window-size adaptation while correcting native
  display integration. No UI control or unrelated navigation was added.
