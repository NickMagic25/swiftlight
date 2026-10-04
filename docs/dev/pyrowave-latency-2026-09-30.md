# PyroWave latency investigation, September 30, 2026

The current Debug implementation could receive a 3440×1440, 165 FPS, HDR10,
4:4:4 PyroWave stream while presenting only about 46 distinct frames per second.
The dominant delay occurred before decoded output reached the renderer.

The native decoder's CPU coefficient validation was compiled without optimization.
A 293,160-byte synthetic frame took 4.27 ms median CPU preparation and 6.81 ms
from admission to its GPU-completion callback, exceeding the 6.06 ms frame
interval before rendering.
Optimized native Debug reduced those medians to 0.315 ms and 1.84 ms. See the
decoder's `docs/pyrowave.md` for the benchmark and its offscreen limitations.
The live scene's roughly 760 KB access units cost substantially more in the
original build.

common-c's 15-unit FIFO then accumulated stale compressed frames while the pull
worker synchronously submitted each unit. At 165 FPS the queue can represent
roughly 91 ms. Only independent, unadmitted PyroWave units can be replaced; admitted
decoder work retains its terminal completion and HEVC/AV1 remain ordered.
Selection drains at most 15 queued units, completes each superseded handle exactly
once, and preserves the selected unit's frame identity, sequence header and timing.
`compressedStaleSkips` distinguishes these local skips from network loss and
decoded-mailbox replacement.

The native packet receiver, RTP assembly and FEC code also used unoptimized Debug
compilation. Decoder optimization alone removed the large queue delay, but three
repeats still had variable presentation cadence. The final build enables `-O2`
for both native decoding and `CStreamBridge` in Debug while preserving symbols,
decoder assertions and the transport's existing assertion policy. Swift
application Debug compilation remains unchanged. No decoded
pixel copies, shader changes or synchronous GPU waits were added. The decoder's
CMake build exposes `MAV_OPTIMIZED_DEBUG=OFF` to reproduce its original baseline.

## Live comparison

The signed Xcode Debug app used an Apple M3 Mac on macOS 27, a 3440×1440 165 Hz
display, immediate pacing, VSync off, three drawables, HDR10 4:4:4, manual
1,000 Mbps and System Spatial 7.1 audio. The paired host's existing Desktop
application stayed running across local disconnects. The visible candidate scene
was an animated browser motion test. The destination browser reported a VSync
failure, so this is client delivery evidence rather than a controlled source
animation-cadence benchmark.

The video sockets used Tailscale with a direct LAN peer endpoint. The Mac's
Ethernet adapter negotiated 2.5 Gb/s. Ethernet capability and the requested
bitrate do not establish actual end-to-end throughput. The dominant measured
baseline issue was local decoder/queue delay; this test does not attribute all
remaining packet loss to a particular network component.

The native decoder benchmark isolates its optimization change. The live trials
also contain host, network and compositor variation, so the better final trial
does not isolate the transport optimization's individual contribution.

Each row uses at most 1,024 recent distinct decoded frames with confirmed
drawable presentation, joined to that frame's renderer completion. These are
bounded end-of-trial windows, not whole-session averages or physical scanout.

| Run | First packet to presentation mean / p95 | Enqueue to admission mean | Confirmed presentation FPS |
| --- | --- | --- | --- |
| Original Debug | 80.60 / 123.94 ms | 42.90 ms | 46.44 |
| Decoder optimization + queue selection, trial 1 | 19.97 / 25.78 ms | 0.70 ms | 145.10 |
| Decoder optimization + queue selection, trial 2 | 21.12 / 27.76 ms | 0.74 ms | 114.92 |
| Decoder optimization + queue selection, trial 3 | 22.04 / 28.75 ms | 0.79 ms | 108.73 |
| Both native paths optimized, trial 1 | 17.50 / 25.01 ms | 0.50 ms | 161.36 |
| Both native paths optimized, trial 2 | 20.94 / 27.34 ms | 0.91 ms | 133.15 |

Candidate 1 decoded 9,186 accepted units with no decoder failures, rejected 81
admissions, and recorded 20 local compressed stale skips. The renderer submitted
9,171 commands and recorded 894 callbacks without a usable presentation timestamp;
these contribute no latency sample and are separate from packet loss. Its final
window contains 1,021 distinct presentation instants among 1,024 decoded-frame
records. Its final-window packet-to-enqueue mean remained 5.98 ms,
and renderer commit-to-presentation remained 8.09 ms. The original matched
packet-to-decoder-callback mean was 72.79 ms; candidate 1 reduced it to 11.73 ms.
Lower latency accompanied higher confirmed cadence, although the candidate did
not confirm a presentation for every 165 Hz refresh.

The final build's first trial lasted 116.7 seconds. It decoded 18,719 accepted
units with no decoder failures, rejected five admissions and recorded no local
compressed skips. The renderer submitted 18,714 commands; 382 callbacks lacked a
usable presentation timestamp. Network loss was 63 of 18,782 reported network
frames (0.34%).

Its second trial lasted 485.0 seconds. It decoded 76,915 units with no decoder
failures, rejected 1,476 admissions and recorded 102 local compressed skips.
There were 1,162 decoded-mailbox replacements and 13,338 unconfirmed presentation
callbacks among 75,754 renderer submissions. Network loss was 3,261 of 79,087
reported network frames (4.12%). The final presentation window had 1,014 distinct
instants among 1,024 decoded-frame records. These observations establish that the
large backlog was removed, but also show remaining cadence variability: the
best run must not be treated as sustained 165 FPS acceptance. Network loss,
decoder admission rejection and missing presentation timestamps are separate
observations; this comparison does not isolate their remaining causes.

Every table row exported captured input, native full screen and the same saved
stream settings. The final trial windows had the statistics overlay visible.
An additional exploratory export with released input is retained locally but
excluded from the matched comparison.

Raw exports, analysis JSON/text, binary hashes and build/test logs are retained in
the ignored `artifacts/pyrowave-latency-2026-09-30/` directory. Both repositories
have uncommitted PyroWave work; a branch HEAD alone does not identify either tested
binary. The preserved original and final bundles remain in distinct Derived
Data directories. `binary-hashes.json` identifies intermediate and final binaries;
`source-manifest.json` records the final dirty source files and their hashes.

## Verification and limits

- Signed macOS Xcode Debug build and live stream with the requested format.
- Repository CI gate passed again after both native optimization changes; its
  hardware tests are intentionally disabled.
- Hardware offline gate passed, including production decoder/Metal readbacks.
- Native transport ASan/UBSan and separate TSan gates passed, including queue
  ownership/cancellation cases; decoder Metal lifetime checks also passed with
  both sanitizer configurations.
- iPhone and iPad simulator Xcode Debug builds passed again with both native paths
  optimized. These establish compilation, not physical-device streaming or latency.

The live comparison does not establish calibrated HDR appearance, physical
input-to-photon timing, a long-duration thermal result or full 165 FPS presentation
acceptance. The decoder's VideoToolbox-only timing series remains unavailable for
PyroWave; neither requested FPS nor a different timing window substitutes for it.

## Direct presentation follow-up

The Metal HUD continued to report **Composited** after the latency fix. The
user also observed this without automated screenshot capture. Current HEVC HDR
controls reproduced better timing, but also reported Composited. Both codecs
render into the same opaque RGB drawable and use the same presentation code;
PyroWave's private Y/Cb/Cr textures and HEVC's imported Core Video textures are
shader inputs, not separate Core Animation presentation paths.

The Mac video view now truthfully reports opaque coverage, including its black
letterboxes and the black backing outside a safe-area video layer. Making the
Metal layer the view's root did not enable Direct, so that placement remains a
Debug experiment. Native full screen, opaque window/view/layer, full display
drawable size and `presentsWithTransaction = false` were confirmed in exports.

The following controls retained 3440×1440 at 165 Hz, immediate pacing, three
drawables, HDR On and captured input. PyroWave used 4:4:4 at manual 1,000 Mbps;
HEVC used manual 150 Mbps. Statistics were hidden in their final exported windows.
Every row uses 1,024 recent distinct decoded-frame records with confirmed
presentation, rather than the Metal HUD's FPS or present-delay summaries.

| Control | First packet to presentation mean / p95 | Commit to presentation mean | Confirmed presentation FPS | HUD mode |
| --- | --- | --- | --- | --- |
| HEVC HDR, current opaque child layer | 7.48 / 15.60 ms | 4.64 ms | 159.37 | Composited |
| PyroWave HDR, current opaque child layer | 20.45 / 27.17 ms | 7.12 ms | 137.97 | Composited |
| PyroWave, cache HDR metadata before acquiring drawable | 22.44 / 26.34 ms | 9.41 ms | 147.25 | Composited |
| PyroWave, native PQ root layer, VSync off | 20.53 / 25.74 ms | 9.53 ms | 154.38 | Composited |
| PyroWave, native PQ root layer, VSync on | 28.15 / 31.91 ms | 16.96 ms | 164.83 | Composited |
| Installed September 15 Swiftlight, HEVC HDR | 9.41 / 19.34 ms | 6.63 ms | 159.85 | Composited |

Additional exploratory root-layer linear HDR trials with VSync off and on, and
HEVC controls using the preserved pre-follow-up child-layer build, also reported
Composited. The native PQ trial changes output format/color space and disables
legacy EDR metadata; it does not establish calibrated HDR equivalence. None of
these rendering experiments has been promoted to the default.

The current HEVC/PyroWave difference is mostly earlier than presentation. Joining
each frame's own timestamps, the 12.98 ms mean difference includes 6.02 ms in
first-packet-to-complete-frame enqueue, 0.69 ms in enqueue-to-admission and 3.93 ms
in admission-to-decoder callback. The same-frame renderer adds 0.63 ms GPU
execution and 1.84 ms GPU-end-to-presentation. These additive stages distinguish
the larger PyroWave access unit and decoding path from the HUD mode; they do not
isolate wire serialization, socket processing or individual decoder stages.

Optional bounded `decodedColor` diagnostics were added on Mac and mobile to
compare the actual HDR metadata. Both current streams deliver BT.2020/PQ with
limited range. HEVC supplied no mastering/content-light metadata; PyroWave
supplied Rec.2020/D65 mastering coordinates, 730 nit maximum and 0.5748 nit
minimum, with no content-light metadata. The PyroWave minimum is correctly
converted from the transport's 1/10,000-nit units. These are reported host values,
not measured display luminance. Caching reduced metadata assignment from once
per presentation to one assignment in the trial, without enabling Direct.

[Apple's Metal window guidance](https://developer.apple.com/documentation/metal/managing-your-game-window-for-metal-in-macos)
documents native full screen, opaque RGB Metal content and Apple silicon as the
usual requirements, allows all Metal-layer RGB formats, and notes additional
hardware/system conditions. The tested configuration meets those documented
requirements, but Direct presentation has not been achieved or its remaining
blocker isolated in these controls. The older installed HEVC control means this result cannot be
attributed to the new PyroWave decoder alone.

Follow-up exports, analyses and signed Mac/iPhone/iPad build logs are retained in
`artifacts/direct-presentation-2026-09-30/`. The HDR diagnostic unit tests and
display/window lifecycle harnesses are recorded there separately from live
presentation evidence. The original PyroWave/HDR/4:4:4/1,000 Mbps settings and
VSync-off baseline are restored after the comparison.

The user subsequently reported that explicitly setting **Custom FPS** to 165
instead of zero enabled Direct and brought average first-packet-to-display timing
to roughly 14 ms. The subsequent [native decoder investigation](pyrowave-decoder-latency-2026-09-30.md)
retains explicit 165 FPS and focuses on CPU preparation and Metal execution.
The earlier Composited controls above describe their recorded configuration;
they do not establish the current HUD mode at explicit 165 FPS.
