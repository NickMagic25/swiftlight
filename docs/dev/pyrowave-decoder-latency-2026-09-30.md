# PyroWave decoder latency, September 30, 2026

The user found that an explicit 165 FPS setting improved presentation compared
with the display-derived setting of zero. This follow-up retains explicit 165 FPS
and focuses on native decoding. It does not investigate Direct presentation.

## Live stage baseline

The signed Xcode Debug stage build used the local decoder checkout on an Apple
M3 Mac, 3440 × 1440, HDR10 4:4:4, manual 1,000 Mbps, immediate pacing, VSync off,
three drawables and System Spatial 7.1 audio. Input was captured and the Metal
statistics panel was visible. The actual video socket used the Tailscale
interface. The remote application remained running across local disconnects.

The bounded final window contains 1,024 distinct decoded-frame identities with
confirmed drawable presentation. Its first-packet-to-presentation mean is
14.28 ms, p95 19.22 ms, with 152.82 distinct presentation instants per second.
These are recent-window measurements, not whole-session averages or physical
scanout. The user changed stream settings during the earlier interrupted
measurement, so the system-wide UDP counter interval is exploratory and cannot
serve as a matched route comparison.

| Same-frame native stage | Mean | p95 |
| --- | ---: | ---: |
| CPU preparation and validation | 1.889 ms | 2.607 ms |
| Preparation end to backend entry | 0.004 ms | 0.011 ms |
| Backend parsing and resource acquisition | 0.110 ms | 0.209 ms |
| CPU upload and Metal encoding | 0.115 ms | 0.253 ms |
| Native return to GPU commit | 0.001 ms | 0.003 ms |
| GPU commit to execution | 0.211 ms | 0.382 ms |
| Decode GPU execution | 1.750 ms | 2.977 ms |
| GPU end to decoder callback | 0.123 ms | 0.208 ms |
| Admission to decoder callback | 4.203 ms | 5.736 ms |

The detailed stages reconcile to each frame's admission-to-callback interval;
they are not differences between unrelated averages. GPU start/end are mapped
to the decoder's monotonic clock with a bracketed calibration and explicit
uncertainty. VideoToolbox-specific fields remain unavailable for PyroWave.

The stage-only app is preserved at `.build/xcode-pyrowave-stage/`. Its executable
hash and dirty source hashes are recorded in
`artifacts/pyrowave-stage-2026-09-30/baseline-source-manifest.json`. The baseline
export and analysis are in the same ignored directory. The earlier simultaneous
synthetic benchmark and live stream are excluded from performance comparisons.

An additional baseline session at the same settings produced a final 1,024-frame
window of 12.93 ms first-packet-to-presentation, p95 16.80 ms, and 146.46 distinct
presentation instants per second. Native decoding averaged 4.17 ms: CPU preparation
1.52 ms and decode GPU execution 2.18 ms. These two windows illustrate variation
in CPU, GPU and presentation costs before any decoder optimization; an unmatched
total-latency change is insufficient evidence of a decoder improvement.

## GPU utilization

A 30-second live sample read `AGXAccelerator`'s `PerformanceStatistics` once per
second while the preserved stage-only app streamed at explicit 165 FPS. Device
utilization averaged 59.57%, with a 46–75% range. These are system-wide driver
percentages, including decoding, rendering, the visible Metal HUD and other Mac
activity. They do not measure shader occupancy or attribute utilization to the
decoder. No other agent build or GPU benchmark ran during this capture.

A separate ten-second library sample averaged 44% device utilization. Its
different window and background workload prevent subtracting it from the stream
sample to estimate decoder utilization. The individual anonymized scalar samples
are in `gpu-utilization-live165.json` and `gpu-utilization-idle.json` under the
ignored stage artifact directory. Privileged `powermetrics` was unavailable
without administrator authentication; no privileged GPU counters were collected.

The saved host setting subsequently changed to 1,500 Mbps. Fresh matched baseline
and CPU-candidate sessions retained it and explicit 165 FPS. Separate 30-second
samples recorded 68.13% mean device utilization (61–72%) for the baseline and
71.90% (63–76%) for the candidate. The shader is identical in both builds. These
system-wide windows cannot be used as a per-decoder utilization comparison or a
shader-occupancy measurement; accepted cadence, other activity and GPU frequency
can differ. No agent compilation, test or GPU benchmark ran during either sample.

## Optimization candidates

An isolated measurement found that constructing the validator's block-layout
mapping takes roughly 0.028 ms, too little to explain the live CPU preparation
cost. That layout remains unchanged.

The retained CPU changes validate fragment-map tiling and kinds once, then avoid
repeated packet-boundary searches when no fragment is lost. Any missing fragment
uses the original recovery path. Coefficient validation still checks record,
magnitude and sign bounds: it checks the aggregate magnitude length once,
advances unused zero-control-word magnitudes without scanning them, and combines
eight disjoint coefficient masks into one population count. No rejection rule or
decoded-plane storage/precision changes.

On a fixed legal 757,572-byte access unit with 6,338 coefficient records,
preparation median decreased from 0.965 ms to 0.709 ms with the intact-fragment
path alone, then to 0.627 ms with both CPU changes, about 35% below the original.
A dense 757,368-byte fixture's matched coefficient-only comparison decreased from
0.630 to 0.513 ms median, p95 0.708 to 0.589 ms. Accepted bytes and all three
decoded-plane hashes matched. These are isolated sequential decoder measurements,
not live network/presentation results or PQ appearance validation.

The default Metal inverse-wavelet kernel contains an apron barrier whose
preceding reads and writes address disjoint regions from the main lifting pass.
An isolated removal retained the following synchronization and produced bit-exact
planes across ten edge-dimension, chroma and depth cases. However, alternating
original/candidate pipelines in one process showed no consistent GPU improvement:
at 3440 × 1440, 4:4:4 R16, a 999,788-byte fixture measured 1.27017/1.27167 ms
median, and a repeat measured 1.26987/1.26762 ms. The original shader was restored;
the ignored native build artifacts preserve the experiment. No precision, texture
layout or shader change is included in the live candidate.

## Live CPU-candidate comparison

Both sessions used the current saved 1,500 Mbps setting, explicit 165 FPS,
3440 × 1440, HDR10 4:4:4, immediate pacing, VSync off, three drawables, captured
input, visible detailed statistics and the same Tailscale route. Default extended
linear sRGB/rgba16Float output and all rendering experiments remained unchanged.
Executable paths were verified during each run; the baseline bundle was not
rebuilt. Each row is the final 1,024-frame window with confirmed presentation,
joined to that frame's decode and render completion.

| Same-frame measurement | Stage-only baseline mean / p95 | CPU candidate mean / p95 |
| --- | ---: | ---: |
| CPU preparation | 2.753 / 3.272 ms | 2.007 / 2.418 ms |
| Decode GPU execution | 1.863 / 3.341 ms | 1.876 / 3.366 ms |
| Native admission to callback | 5.286 / 6.808 ms | 4.546 / 5.961 ms |
| First packet to complete-frame enqueue | 6.891 / 8.726 ms | 6.838 / 8.294 ms |
| First packet to confirmed presentation | 18.072 / 22.259 ms | 16.702 / 20.219 ms |
| Confirmed distinct presentation instants per second | 127.33 | 135.54 |

CPU preparation decreased about 27% in these live windows, consistent with the
isolated fixed-input validation improvement. Metal execution stayed essentially
unchanged, as expected from the identical shader. Native stages reconcile to
their same-frame total in all 1,024 samples of both windows.

The whole sessions lasted 178.3 and 136.5 seconds, with 21,989 and 17,413 accepted
native units and zero decoder failures. Acquired access units averaged
1,134,062 and 1,134,033 bytes. The reported network-loss counters were
11,732/28,484 (41.19%) and 7,591/22,030 (34.46%). These count network-imperfect
frames separately from native rejection; partial recovery can still produce
output. Missing/invalid presentation callbacks were 452 and 381, separately
excluded from latency measurements. The candidate recorded six compressed stale
skips and six renderer capacity skips.

The high and differing network loss prevents attributing the complete 1.37 ms
presentation decrease or cadence change solely to the CPU optimization. These
runs do not establish stable 165 FPS delivery at 1,500 Mbps. The approximately
6.8 ms packet-to-complete-frame stage remains larger than CPU preparation or
Metal execution; it does not isolate host pacing, wire serialization, Tailscale
or receiver processing. No network preference or saved host identity was changed.
The current saved 165 FPS/1,500 Mbps configuration is retained.

The signed CPU candidate is at `.build/xcode-pyrowave-decode-fast/`. Its source
and binary hashes, both live exports and analyses, GPU samples and validation
logs are in `artifacts/pyrowave-stage-2026-09-30/`. Native benchmark, oracle and
sanitizer evidence is in the decoder's `.build-pyrowave/cpu-validation-evidence.md`
and the corresponding `.build-pyrowave-asan/` and `.build-pyrowave-tsan/` logs.

## Verification and remaining acceptance

- Signed macOS Xcode Debug app build, signature verification, launched candidate
  and real PyroWave stream through the production adapter/renderer.
- Full Swiftlight CI and hardware offline gates passed against the local decoder
  checkout. The offline run had no hardware skips and passed all eight
  HEVC/AV1 decode, Metal readback and configuration-change fixtures.
- Native scalar-oracle, malformed/truncated/partial framing, additive ABI,
  lifecycle, actual Metal output/trace-order and retained-output teardown checks
  passed, including ASan/UBSan and a separate TSan run.
- iPhone 17 Pro and iPad Pro simulator Xcode Debug builds passed against the local
  decoder on iOS 26.5 destinations using Xcode/SDK 27.0. These are compilation
  checks; they do not establish mobile hardware streaming or presentation.
- Whitespace checks passed in both working trees. Existing uncommitted PyroWave
  work was preserved; no commit, push or dependency publication was performed.

The first restricted CI invocation could not open its loopback TLS listener and
ImageIO fixture decoder. Both passed when the same tests were rerun with normal
system access, followed by a complete successful CI and offline gate. Those
initial environment failures are retained in their separate log.

Physical scanout/input-to-photon timing, calibrated HDR appearance, a thermal
soak and sustained 165 FPS cadence remain separate acceptance. Simulator and
offscreen results do not substitute for them. Current builds use the explicit
local decoder override; the committed remote decoder pin was not published or
changed as part of this work.
