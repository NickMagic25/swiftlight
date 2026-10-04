# PyroWave native validation handoff — October 3, 2026

Swiftlight no longer implements its own PyroWave coefficient, sequence,
geometry, duplicate-block or completeness validator. `CPyrowaveBridge` sends
codec records to the pinned native decoder, asks it whether decoding is ready,
and retains its three GPU planes through rendering. The fork remains at
`56b007143b471def3e41d5e74d10f73dfc8c8df1`; no fork or Apple decoder changes
were needed for this handoff.

## Remaining transport adaptation

`SPyrowaveParser.cpp/.hpp` and the client coefficient-validator test oracle were
removed. `SPyrowaveInput.cpp/.hpp` only extracts Vibepollo's outer framing:

- Skip padding records and unwrap the legacy count/length container.
- Bound byte spans, word alignment and transport fragment descriptors before
  passing borrowed ranges into native typed loads.
- Omit lost transport payloads and use the host's critical-packet sideband.

The adapter does not inspect coefficient controls, magnitudes or signs, construct
codec block layouts, reject duplicate blocks, or reconstruct sequence/count
rules. Padding bodies are skipped without a zero-byte scan. The pinned native
parser defines codec acceptance; its structural checks are not equivalent to
the removed coefficient grammar validator.

For an intact frame, native readiness requires all announced blocks. For a
partial frame, native readiness applies its packet-ratio threshold and uses its
pristine-band check when host critical-packet sideband is unavailable. Rejected
submissions consume no callback context. A following independent frame clears
native parsing state. Bounded admission, asynchronous GPU completion, generation
handling, retained output leases and the production renderer are unchanged.

## Offscreen comparison

The same production benchmark ran in A/B/B/A order: A retains the old client
validator; B uses the new transport adapter. Both use the same pinned fork,
3440 × 1440 4:2:0 ramp, 10-bit output, 165 FPS admission, capacity two,
120 warmup frames and 480 measured frames per run. Native bridge optimization
is enabled in these SwiftPM debug builds. No network or drawable exists.

| Run | CPU preparation mean | Decode admission → callback mean | Decode GPU mean |
| --- | ---: | ---: | ---: |
| A1 | 0.300 ms | 2.854 ms | 1.985 ms |
| B1 | 0.055 ms | 2.702 ms | 1.945 ms |
| B2 | 0.049 ms | 2.129 ms | 1.376 ms |
| A2 | 0.512 ms | 2.598 ms | 1.408 ms |

The CPU preparation reduction is consistent across the runs. GPU timing varied,
so the aggregate decode differences do not isolate a universal latency gain.
All runs completed all 600 accepted frames, with identical production-renderer
RGBA readback hashes. B2 encountered two bounded capacity retries; the other runs
encountered none. All recorded thermal states were nominal and low-power mode
was off. Raw reports, executable hashes and retry/lateness data are retained in
ignored `artifacts/pyrowave-native-validation-2026-10-03/`.

## Live Release verification

The signed Xcode Release build streamed from the existing paired test host with
saved settings unchanged: 3440 × 1440, requested 165 FPS, PyroWave HDR10 4:4:4,
1500 Mbps, immediate pacing, VSync off, three drawables and statistics visible.
Native output and live statistics were inspected. The session ended by local
disconnect; the remote application was left running.

The completed session accepted and completed 5,966 frames with zero failed
decoder completions. A joined window of 1,024 distinct confirmed presentations
reported these means:

| Same-frame stage | Mean |
| --- | ---: |
| CPU preparation | 0.307 ms |
| Decode admission → callback | 2.867 ms |
| First packet → complete-frame enqueue | 6.848 ms |
| Complete-frame enqueue → admission | 0.492 ms |
| Render GPU execution | 0.983 ms |
| Render GPU end → confirmed presentation | 3.001 ms |
| First packet → confirmed presentation | 14.445 ms |

The earlier retained Release session measured 1.798 ms CPU preparation and
13.097 ms first packet → presentation. These are different live sessions and
frame populations, not a controlled A/B comparison. The new session's longer
post-render presentation interval prevents claiming an overall display-latency
reduction from removing validation. Confirmed drawable presentation does not
establish physical scanout or input-to-photon latency.

The redacted export is `live-release.json` in the ignored artifact directory,
SHA-256 `bb7ba2a8838a40d249695cee0f1282a2df94e97fc80d4b2c60987109d14153f0`.
`scripts/analyze-stream-latency.py` produced `live-analysis.json/.txt`; all native
GPU stages joined successfully for the 1,024-frame presentation population.

## Checks and remaining scope

- `scripts/validate-ci.sh`: passed with local socket/system-service access.
  The first sandboxed run blocked TLS sockets and system image decoding; the
  rerun passed without source changes.
- `scripts/validate-offline.sh`: passed, including five production PyroWave
  tests, all four codec/depth profiles, native rejection/recovery, duplicate
  acceptance and retained output rendering, plus the HEVC/AV1 fixture replays.
- `scripts/validate-pyrowave-native.sh address` and `thread`: passed with real
  Metal access; ASan/UBSan and TSan checked framing, admission, upload-ring reuse,
  partial recovery and output lifetime across reset/destruction.
- Primary `Swiftlight.xcodeproj` / `Swiftlight` macOS Release build and strict
  signature verification: passed. The built app was launched for the live run.
- Decoder source audit, pristine submodule verification and whitespace checks:
  passed.

Physical iPhone/iPad verification and a controlled live presentation A/B remain
unexecuted. At this validation checkpoint, changes were local on
`codex/pyrowave`; nothing had been committed or pushed.
