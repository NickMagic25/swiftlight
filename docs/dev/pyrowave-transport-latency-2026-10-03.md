# PyroWave transport latency investigation — October 3, 2026

The new per-frame transport clocks locate most pre-decoder delay **before the
decisive packet is received in userspace**. Final FEC processing and frame
depacketization after that receipt average less than 0.1 ms in these runs.
Instrumentation and analysis were added; no production pacing, decoder,
quality or rendering policy changed. Near-HEVC gaming latency remains unproven.

## Measurements

Three signed Release runs used a mostly static desktop at 3440 × 1440 HDR10,
165 requested FPS, immediate presentation, VSync off, three drawables and a
hidden statistics overlay. Actual presentation cadence was much lower than
165 FPS. The layer remained a child Metal layer with linear-sRGB `rgba16Float`
output. Exports and detailed findings are retained locally under
`artifacts/pyrowave-transport-investigation-2026-10-03/`, ignored by Git.

| Capture | Presented samples | Median payload | First packet → presentation mean / p95 | Confirmed instants/s | Sample span |
|---|---:|---:|---:|---:|---:|
| PyroWave, 1500 Mbps | 407 | 1,140,516 B | 20.961 / 28.092 ms | 16.960 | 23.938 s |
| PyroWave, 500 Mbps | 1024 | 383,444 B | 16.539 / 24.145 ms | 16.954 | 60.339 s |
| HEVC, 150 Mbps | 1024 | 1,000 B | 10.683 / 19.204 ms | 22.059 | 45.876 s |

The following additive means use the same complete frames within each column:
406 for PyroWave 1500, and 1024 for each other capture. The remaining PyroWave
1500 frame was explicitly partial and correctly omitted decisive-receipt
timing. All payloads were present, endpoint order was valid, and additive
residuals were within floating-point precision. No duplicate frame identities
or diagnostic join evictions appeared.

| Stage mean, ms | PyroWave 1500 | PyroWave 500 | HEVC 150 |
|---|---:|---:|---:|
| First packet → decisive receipt | 11.620 | 6.752 | 0.008 |
| Decisive receipt → final FEC ready | 0.015 | 0.016 | 0.002 |
| Final FEC ready → access-unit availability | 0.080 | 0.048 | 0.004 |
| Availability → queue offer | 0.00014 | 0.00020 | 0.00037 |
| Queue offer → native frame handoff | 0.209 | 0.140 | 0.027 |
| Handoff → decoder admission | 0.181 | 0.156 | 0.020 |
| Decoder admission → callback | 3.858 | 3.989 | 1.945 |
| Decode callback → render commit | 0.169 | 0.252 | 0.377 |
| Render GPU scheduling | 0.234 | 0.327 | 0.532 |
| Render GPU execution | 0.948 | 0.993 | 1.139 |
| GPU finish → API-confirmed presentation | 3.640 | 3.866 | 6.630 |
| **First packet → presentation** | **20.955** | **16.539** | **10.683** |

Approximately 99% of first-packet-to-availability time precedes decisive
receipt in both PyroWave runs. This interval still includes host pacing,
delivery, receiver scheduling and processing of earlier packets. It is not a
measurement of physical wire serialization. Final FEC timing does not include
all reconstruction work performed before the decisive receipt.

The smaller PyroWave payload and receive span make a controlled bitrate sweep
useful. These runs differ in duration, warmup coverage and input capture:
input was captured for PyroWave 1500 and HEVC, and released for PyroWave 500.
They have no repeated baseline or accepted quality comparison. PyroWave
negotiated 10-bit 4:4:4; HEVC reported 10-bit without a 4:4:4 marker and uses
the current renderer's NV12/P010 4:2:0 path. HEVC's tiny static-frame payloads
also represent a different workload. These results do not establish a
codec-only or gaming improvement.

Decoder failures, rejections and capacity blocking were zero throughout.
The PyroWave 1500 session reported two lost network frames of 410; the other
sessions reported none. HEVC recorded one decoded-frame presentation skip
and 247 unusable presentation callbacks across its longer session. Such
callbacks are excluded from latency samples, not counted as measured drops.
Session counters and bounded frame windows cover different populations.

## Sender pacing hypothesis

Inspected Vibepollo source at commit
`6c4a3e1e0d74f2309db23768a2b7ee90ed2321c3` uses routed link capacity for
PyroWave packet pacing when available. Otherwise it uses the larger of nominal
frame demand and negotiated bitrate demand. A frame that fills that budget can
therefore consume approximately one nominal frame interval before overhead:
6.06 ms at 165 FPS. The inspected sender charges both data and parity against
the allowance. This is a source-backed hypothesis; the installed host revision
and active pacing mode were not verified. The 1500-Mbps receive span is longer
than that simple estimate. See the [pacing calculation](https://github.com/Nonary/Vibepollo/blob/6c4a3e1e0d74f2309db23768a2b7ee90ed2321c3/src/pyrowave_policy.cpp#L717-L734)
and [sender implementation](https://github.com/Nonary/Vibepollo/blob/6c4a3e1e0d74f2309db23768a2b7ee90ed2321c3/src/stream.cpp#L2251-L2355).

The inspected Windows capacity probe returns zero for tunnel and Wi-Fi
interfaces. A Tailscale peer check reported direct LAN delivery, but that does
not establish that media bypassed the tunnel or that the host route reports
usable Ethernet capacity. The PyroWave branch also overrides the generic
pacing/batch settings; `pyrowave_send_rate_mbps` is documented as ignored.
See [route detection](https://github.com/Nonary/Vibepollo/blob/6c4a3e1e0d74f2309db23768a2b7ee90ed2321c3/src/platform/windows/misc.cpp#L1847-L1887)
and the [host rate-control contract](https://github.com/Nonary/Vibepollo/blob/6c4a3e1e0d74f2309db23768a2b7ee90ed2321c3/docs/pyrowave-protocol.md#L143-L196).

The next host evidence is its `PyroWave pacing` log, especially
`routed_link_bps`, `packets/ms` and any fallback marker, plus send-burst and
paced-sleep durations. An SSH attempt to read host logs timed out. No host
configuration or pacing fix was applied.

## Route attempt, restoration and validation

The user approved a temporary direct-LAN comparison followed by restoration.
A terminal host-information request succeeded, but the signed app failed with
`-1009`; the system log reported `Local network prohibited`. Local Network
permission already appeared enabled. Refreshing it back to enabled, restarting
and retrying did not resolve the restriction. Adding the direct address never
succeeded, so that attempt produced no direct-LAN stream or fourth capture.
It left the saved Tailscale address and pairing state unchanged.

Original stream preferences were restored, saved and verified in the UI:
PyroWave, 1500 Mbps, 4:4:4, HDR, Native resolution and 165 FPS. The captures
used 3440 × 1440 on a 165-Hz display; the current settings surface later
reported 2560 × 1440 at 60 Hz. Restoring the Native
preference does not restore physical display dimensions or refresh rate.

Focused tests, `validate-ci.sh`, hardware/offline
validation, native ASan/UBSan, separate TSan and the Xcode `Swiftlight` Release
build passed. Offline/manual acceptance still has blocked or skipped gates;
these checks do not establish distribution or physical-device acceptance.

The universal iPhone/iPad Simulator app also compiled for arm64 and x86_64
with `IPHONEOS_DEPLOYMENT_TARGET=26.0 CODE_SIGNING_ALLOWED=NO` supplied on the
command line. The first attempt exposed Simulator's unavailable
`MTLDrawable.drawableID`; Simulator builds now omit that diagnostic identity.
The next attempt encountered the existing project's deployment-target expression
resolving below the supported minimum. The final command supplied 26.0 while
preserving existing project edits. This verifies compilation, not iPhone/iPad
Simulator execution or physical-device streaming.

At that point, remaining evidence was a repeatable moving scene with stable
received and presented cadence, controlled repeated codec/bitrate runs, accepted image
quality, verified host pacing logs and an overlapping Instruments/JSON capture.
API-confirmed presentation does not measure physical scanout. See the
[capture procedure](stream-latency-debugging.md#separate-packet-receipt-from-receiver-work)
and [export schema](diagnostic-exports-schema.md).

## Follow-up: moving scene over Ethernet

Later that evening, the user configured a local hostname and enabled IPv4 and
IPv6 on the host. Successful streams then used the same moving TestUFO scene
over client interface `en6`. The saved hostname and pairing were preserved;
no address replacement was made during this sequence. The failed
`pyrowave-lan-1500-A.json` negotiation export has no decoder results and is
excluded. These captures use the same instrumented Release executable,
SHA-256 `a9922f9a77fcf171d5783e047fc7bf97ef4993837c36452a9f9837ea3c42a306`;
no build or policy change occurred between runs.

An initial successful-stream screenshot showed TestUFO's synchronization-failure
banner. This was a repeated moving pattern, not a validated 240-FPS or
animation-phase reference. Native received stream FPS is measured separately.

The successful runs report 3440 × 1440 on the 165-Hz display, immediate
presentation, VSync off, three drawables, HDR and captured input. Statistics
visibility differs: PyroWave 1500 B, HEVC 150 B and PyroWave 500 C have statistics
hidden and zero session overlay draws; the other exports show statistics. The overlay
was toggled during the first PyroWave and HEVC sessions; HEVC A then ran for
over 30 seconds with a stable overlay before export. Export state alone does
not establish an unchanged overlay across an entire rolling window. These are
diagnostic comparisons, not a controlled benchmark. The earlier static-desktop results are separate
historical observations, not a controlled before/after baseline for these runs.

| Capture | Statistics at export | Median payload | Receive span mean / p95 | First packet → presentation mean / p95 |
|---|---|---:|---:|---:|
| PyroWave 1500 A | Visible | 1,139,452 B | 4.363 / 4.915 ms | 14.106 / 21.756 ms |
| HEVC 150 A | Visible | 12,376 B | 0.120 / 0.291 ms | 9.002 / 17.338 ms |
| PyroWave 500 A | Visible | 378,556 B | 1.752 / 1.872 ms | 12.734 / 18.533 ms |
| PyroWave 500 B | Visible | 378,556 B | 1.586 / 1.820 ms | 12.639 / 17.377 ms |
| PyroWave 1500 B | Hidden | 1,139,840 B | 4.335 / 4.668 ms | 10.559 / 13.990 ms |
| HEVC 150 B | Hidden | 13,752 B | 0.131 / 0.298 ms | 6.267 / 11.348 ms |
| PyroWave 500 C | Hidden | 378,736 B | 1.608 / 1.869 ms | 8.198 / 12.553 ms |

Each latency row uses 1024 confirmed frame samples. PyroWave 500 A includes one
partial frame with unavailable decisive-packet timing; its receive-span row
uses the remaining 1023 frames. It also contains a 102.938-ms receive-span
outlier and a 138.253-ms total-latency outlier. Its network-loss counter rises
from zero to 26 during the final approximately ten seconds. All outliers are
retained.

The 1500-Mbps second run has essentially the same receive span, but lower
decoder admission-to-callback time, 3.629 → 2.537 ms, and post-GPU time,
4.215 → 2.039 ms. Its total falls by 3.547 ms with statistics now hidden.
This is not a matched repeat and cannot isolate an overlay effect or ordinary
timing drift. The 500-Mbps second run retains the smaller receive span but has
7.144 ms of post-GPU delay and a 12.639-ms total with statistics visible.
Total changes across those groups cannot be attributed solely to bitrate.

With statistics hidden, PyroWave 500 C measures **8.198 ms mean / 12.553 ms
p95**, versus **10.559 / 13.990 ms** at 1500 Mbps and **6.267 / 11.348 ms** for
HEVC. The observed mean reduction from 1500 to 500 Mbps is **2.361 ms (22.4%)**;
the remaining HEVC gap is **1.931 ms mean and 1.205 ms p95**. The 500-C capture
has no network loss or partial frames, and all 1024 additive paths reconcile.
Each hidden condition has one run; session length and coverage by usable API
presentation timestamps differ between runs. Image quality was not rated.
This identifies a smaller-payload latency option in these samples, not HEVC
parity or a validated default.

The client link was independently observed as active `2500Base-T` full duplex;
only media/status lines are retained in `lan-interface-proof.txt`. The
approximately 1.14-MB PyroWave access unit alone represents about 3.65 ms at
2.5 Gb/s, before headers and FEC. This is a link-capacity calculation, not an
exact attribution of the measured 4.34–4.36-ms userspace receive span. It makes
smaller payloads or overlapping ingestion more plausible remaining targets
than the measured approximately 0.04–0.05 ms of final FEC/depacketization.

API confirmation coverage must remain distinct from physical display cadence.
Independent recent GPU submissions complete at approximately 163–165/s, and
the final received-FPS timeline stays near 165 except during the 500-A
transient. Confirmed unique presentation timestamps cover only 100–151
instants/s across these windows. Session unconfirmed callbacks are substantial;
missing usable timestamps do not by themselves prove dropped or invisible
frames. These different rolling populations cannot be combined into a physical
display-rate claim.

Detailed paths, audit counts, timeline coverage and the sanitized capture
manifest are in `lan-moving-comparison.json`, `lan-moving-comparison.txt` and
`lan-moving-manifest.json` beside the captures. Host pacing mode, image-quality
acceptance, physical scanout and a synchronized Instruments comparison remain
unverified. No client performance fix has been applied.

After the sequence, the original preferences were restored and saved:
PyroWave 1500 Mbps, HDR, 4:4:4, Native resolution and 165 FPS. Streaming was
resumed with the test pattern visible and statistics hidden around 21:24 EDT
on October 3 (01:24 UTC on October 4). No saved address was changed and the
remote application was not quit. A repeated, equal-duration comparison with
fixed statistics visibility and an image-quality assessment is the next check
before adopting the 500-Mbps option more broadly.

## User-run game and UFO exports at 21:51 and 21:57 EDT

Two later user exports change the interpretation of the earlier comparison.
The user identified the first as a game with Codex not running, then supplied
a quick run of the same UFO pattern. The latest message did not independently
repeat the Codex-closed condition. Neither export records process state,
per-process GPU activity or an executable hash; filenames beginning
`no-codex` are investigation labels, not telemetry proof.

All rows below use PyroWave 1500 Mbps. The latest UFO export matches earlier
1500 A settings, fixed presentation runtime, render options, `en6`, 1-ms RTT,
captured input and visible statistics. All 9064 submissions in its session
include the statistics overlay. Its native size is 3440 × 1440 at 165 Hz.

| Capture | Statistics | First packet → presentation mean / p95 | Recent GPU completions/s | Unique confirmed timestamps/s |
|---|---|---:|---:|---:|
| Earlier UFO 1500 A | Visible | 14.106 / 21.756 ms | 164.563 | 128.202 |
| Earlier UFO 1500 B | Hidden | 10.559 / 13.990 ms | 163.108 | 149.161 |
| User game, 21:51 file | Hidden | 9.338 / 10.924 ms | 141.188 | 141.178 |
| User UFO, 21:57 file | Visible | **7.806 / 8.427 ms** | **164.992** | **165.008** |

The game export had variable incoming cadence and a different workload. The
latest UFO export removes that major mismatch: its final 30-second received
FPS mean is 164.989, with no network loss. All 1024 retained transport paths
are complete and correctly ordered; durations reconcile with raw clocks and
the additive total. Exact overlapping GPU records also match frame,
submission and drawable identities. Decoder failures, drops and rejections
are zero. The session records one decoded-frame presentation skip and 40
unconfirmed callbacks of 9064 submissions. The retained 1024 presentations
have 1024 distinct timestamps over 6.200 seconds. API events still do not
establish physical scanout.

Payload size and reception remain comparable: the latest median is 1,139,836
bytes and first-to-decisive-receipt mean is 4.320 ms, versus 4.335–4.363 ms
earlier. The larger changes occur later: native decode GPU execution is
1.383 ms, whole admission-to-callback decode is 1.999 ms, and render GPU
finish-to-presentation is 0.239 ms. Earlier 1500 A/B post-GPU means were
4.215/2.039 ms. The improvement is therefore not explained by fewer bytes or
a materially shorter packet-receive span.

The new 1500-Mbps mean is also below the earlier hidden-statistics 500-Mbps
mean of 8.198 ms. The earlier 22.4% reduction remains an observed comparison
under those conditions; it is not a demonstrated bitrate-only effect or a
reason to lower the default. The latest run strengthens a system-load or
presentation-environment explanation, but does not identify Codex or another
process as the cause. A repeated comparison with controlled process state,
the same pattern and per-process CPU/GPU evidence is still needed. A new HEVC
capture in the same quiet conditions is required before claiming the current
gap between codecs.

The raw files are `swiftlight-last-stream-1003-2151.json` and
`swiftlight-last-stream=1003-2157.json`; independent comparability and clock
audits are saved as `no-codex-2151-audit.*` and `no-codex-2157-audit.*` in the
same ignored artifact directory. These exports were analyzed without
launching, controlling or rebuilding the app.
