# Statistics in the Metal video pass — September 13, 2026

Stream statistics now draw into the video drawable. This removes the separate
SwiftUI glass surface that could cause additional display composition. The
controlled comparison below confirms the implementation works during a real HDR
stream, but **does not establish a latency improvement or Direct presentation**.
The new panel averaged 6.959 ms first packet → confirmed presentation at the
30-second checkpoint; the old SwiftUI panel averaged 6.370 ms.

## Rendering and accessibility

Core Text rasterizes the panel off the main/render thread when its rows, position,
backing scale, or available width change. The bitmap contains premultiplied sRGB
RGBA pixels. An immutable cached Metal texture supplies the panel to each video
frame; identical pixels reuse the texture even when placement changes. Superseded
raster work checks cancellation before rendering, between rows, and before
installation. Raster content is limited to 24 rows and 512 characters per line,
with a maximum 520-point width and 4× backing scale.

The renderer draws the panel after the video in the **same render encoder, render
pass, command buffer, and drawable**. It adds no Core Animation layer or display
submission. Texture leases retain earlier images until their GPU work completes.
The shader converts the text colors to the drawable's linear or PQ output space;
PQ white corresponds to the existing 203-nit reference white. The overlay pipeline
is compiled alongside the video pipeline on first use of each drawable format,
so opening statistics does not trigger a new pipeline compilation on that frame.

Retained `NSAccessibilityElement` children expose each row's label and value,
including the waiting-for-statistics state. Their frames follow the actual
clamped Metal placement and use parent-relative accessibility coordinates so they
move with the window. These objects create no extra views or layers. The normal
statistics shortcut and top-left, center, or top-right placement remain available.

Apple documents that additional overlapping app layers can introduce composition
and buffering, and that the Direct path has the least buffering. Drawing the
panel into the existing drawable removes an overlapping surface; the operating
system still chooses the presentation path. [Apple: Discover Metal Performance
HUD](https://developer.apple.com/videos/play/tech-talks/110339/)

## Controlled comparison

Run `statistics-overlay-1789315181254-8200771B` produced twelve live captures on
September 13, 2026, between 15:59:54 and 16:01:55 UTC. All captures report streaming,
input captured, native full screen, 3440 × 1440 HEVC HDR10, approximately 165
received FPS, and no network-lost frames. The third-party external display was
fixed at 165 Hz, with minimum and maximum refresh intervals both 6.060916 ms.
This was not a ProMotion or variable-refresh test.

The four cases used immediate presentation, VSync off, three drawables, the same
legacy linear HDR output (`rgba16Float` / linear sRGB), per-frame EDR metadata,
scheduled-callback instrumentation, and the Apple Metal HUD. Native PQ and the
root-layer experiment were off. Each case reconnected to Desktop, warmed up for
ten seconds, then saved live snapshots at 10, 20, and 30 seconds before teardown.
The captures include pipeline prewarming. The final build subsequently added the
accessibility coordinate fixes, waiting-state accessibility, per-row raster
cancellation, and removal of redundant hidden-panel accessibility updates; the table is not a new measurement of those final changes.

The table uses each **30-second capture's 1,024 confirmed distinct presentation
records**. GPU execution and GPU end → presentation are paired with those same
records; the independent GPU timing array is not substituted. All times are
milliseconds. The p95 uses linear interpolation at `(n - 1) × 0.95`.

| Case / 30-second capture | First packet → presentation mean | p95 | GPU end → presentation mean | GPU execution mean |
|---|---:|---:|---:|---:|
| [1. Statistics hidden, baseline](../../artifacts/statistics-metal-overlay-2026-09-13/controlled/statistics-overlay-1789315181254-8200771B-1-hidden-baseline-legacy-hdr-hud-30s-stats-hidden-1789315214183.json) | 8.910 | 15.354 | 4.553 | 1.077 |
| [2. Old SwiftUI statistics](../../artifacts/statistics-metal-overlay-2026-09-13/controlled/statistics-overlay-1789315181254-8200771B-2-swiftui-stats-legacy-hdr-hud-30s-stats-visible-1789315247657.json) | 6.370 | 9.803 | 2.178 | 1.137 |
| [3. New Metal statistics](../../artifacts/statistics-metal-overlay-2026-09-13/controlled/statistics-overlay-1789315181254-8200771B-3-metal-stats-legacy-hdr-hud-30s-stats-visible-1789315281215.json) | 6.959 | 9.408 | 2.911 | 0.910 |
| [4. Statistics hidden, repeat](../../artifacts/statistics-metal-overlay-2026-09-13/controlled/statistics-overlay-1789315181254-8200771B-4-hidden-repeat-legacy-hdr-hud-30s-stats-hidden-1789315315045.json) | 6.777 | 9.129 | 2.590 | 1.080 |

The other checkpoints show why a single before/after pair is insufficient:

| Case | Mean at 10 s | Mean at 20 s | Mean at 30 s |
|---|---:|---:|---:|
| Hidden baseline | 18.525 | 13.077 | 8.910 |
| Old SwiftUI statistics | 6.326 | 6.441 | 6.370 |
| New Metal statistics | 8.670 | 6.904 | 6.959 |
| Hidden repeat | 6.218 | 7.990 | 6.777 |

The hidden baseline itself drifted from 18.5 to 8.9 ms without an overlay change.
That variation prevents attributing the lower later results to the new panel.
At 30 seconds, the Metal panel has a slightly higher mean and slightly lower p95
than the SwiftUI panel; neither difference establishes a repeatable improvement.
The new panel's GPU time is lower in this run, but that is not evidence of lower
end-to-end latency. The cause of the hidden-baseline drift remains unresolved.

The Metal case recorded 123 texture uploads and 4,886 overlay draws by its
30-second capture, consistent with refreshing text at approximately 4 Hz and
reusing it for video frames. The hidden and SwiftUI cases recorded zero Metal
overlay uploads/draws. GPU in-flight high-water was two in all four cases.

The HUD screenshots captured for the hidden baseline, new Metal panel, and hidden
repeat all showed **Composited**. The old SwiftUI case's composition mode was not
screenshotted. These observations do not demonstrate a transition to Direct.
The Apple HUD itself remained enabled throughout the measured sequence.

Each checkpoint is a bounded recent window, not an average over its preceding
10, 20, or 30 seconds. The final presentation windows span approximately
6.2–7.3 seconds. Unconfirmed drawable callbacks are excluded from latency
statistics: the 30-second cumulative counts were 538/4,931 submissions for the
hidden baseline, 319/4,800 for SwiftUI, 82/4,887 for Metal, and 232/4,943 for the
hidden repeat. These counters are neither network losses nor proof of physical
dropped frames. Different confirmed populations further limit direct comparisons.
`presentedTime` is an OS-reported event; none of these measurements establishes
physical scanout or photon latency.

All twelve snapshots are retained under
[`artifacts/statistics-metal-overlay-2026-09-13/controlled/`](../../artifacts/statistics-metal-overlay-2026-09-13/controlled/).
Artifacts are local investigation files ignored by Git.

## Repeat the comparison

In a `DEBUG` build, select a connected computer with a **Desktop** app, then choose
**Stream → Run Statistics Overlay Comparison**. It reconnects for hidden baseline,
old SwiftUI statistics, new Metal statistics, and hidden repeat, with checkpoints
at 10, 20, and 30 seconds. Keep the host scene, display, full-screen state, and
input capture unchanged; releasing capture exposes stream controls and aborts
the controlled sequence. **Stream → Cancel Latency Comparison** stops the run.

Captures are saved to
`~/Library/Application Support/Swiftlight/LatencyExperiments/` with a shared
`statistics-overlay-<timestamp>-<run ID>` prefix. The runner restores its temporary
stream settings and rendering options afterward and leaves Desktop running on
the host. The old SwiftUI panel is available through the debug comparison only;
normal statistics use the Metal panel.

## Verification

The initial and final hardware-enabled suites each passed all 95 tests
(70 XCTest and 25 Swift Testing). The four overlay tests ran without skips and
cover coordinate placement, texture replacement/lifetime, premultiplied color,
PQ reference white, and sharing the video's command buffer. These validate GPU
output and ownership, not the physical display's tone mapping or scanout.

The final debug bundle was built, code-signed, and verified. Release compilation
also passed, and `git diff --check` was clean. Validation records are
[initial hardware tests](../../artifacts/statistics-metal-overlay-2026-09-13/hardware-tests.log),
[final hardware tests](../../artifacts/statistics-metal-overlay-2026-09-13/hardware-tests-final.log),
[final debug build](../../artifacts/statistics-metal-overlay-2026-09-13/build-final.log), and
[release build](../../artifacts/statistics-metal-overlay-2026-09-13/release-build.log).

The signed debug executable SHA-256 is `09c7ab4bf25f525b248ea21f063220acf8376058e8af1f0ca14133227365895b`.

The final signed build was launched against Desktop after verification. Repeated
Control–Option–Shift–S toggles removed/restored the Metal panel and its accessible
rows while stream controls remained hidden. The final smoke screenshot still
showed Composited mode, 0.93 ms GPU time and 13.08 ms Present Delay. Its detailed
statistics showed approximately 15.6 ms recent mean first packet → display at
approximately 165 received FPS. This separate connection was a functional smoke
check, not another controlled comparison; it confirms that substantial residual
presentation latency remains and the 6.959 ms comparison window is not a sustained
guarantee. The app was left streaming with the new statistics panel and Metal HUD
visible.
