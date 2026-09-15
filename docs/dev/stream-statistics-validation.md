# Stream statistics and shortcut validation

The macOS statistics follow-up passed 62 Swift tests and live UI checks against the existing paired Vibepollo host on September 12, 2026 (America/New_York). This validates the changes below, not all release acceptance gates. The initial statistics build executable SHA-256 is `247909cc4fad6465ff440efb0363bae57b7ec91885211982960e46537253254b`; that build has been superseded by the layout follow-up below.

## Implemented behavior

- Control–Option–Shift–Q releases held remote inputs and disconnects locally without a confirmation prompt. The remote application remains running.
- Control–Option–Shift–S toggles a passive statistics panel without releasing stream input. Control–Option–Shift–Z releases capture to access local controls.
- Settings → Stream Statistics stores Simple/Detailed and Top Left/Top Center/Top Right preferences globally. New preferences default to Simple/Top Center. Changes apply immediately without reconnecting or changing per-host quality settings.
- The panel uses native SwiftUI Liquid Glass on OS 26 and later, with material and accessibility fallbacks. It respects safe areas; only the underlying video ignores them. At this recorded pass, iOS, iPadOS and tvOS integration was future work; no mobile app or OS 27 device was built or tested here. The current shared implementation and mobile checks are tracked in [shared-app validation](shared-client-validation-2026-09-14.md).
- Requested settings remain separate from actual decoded dimensions and RTP receive-rate measurements. Simple mode shows timing averages; Detailed shows min/max/average, decoded color, first-packet-to-presentation timing, and the estimated host-to-display duration. Missing measurements display as unavailable.

The implementation uses Apple's [Liquid Glass API](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views). [Measurement definitions and upstream references](stream-statistics-implementation.md) explain the host metadata, RTP counters, jitter estimator, calibrated drawable clock and latency estimate. Common-c remains a pristine pinned submodule: one additional targeted patch exposes confirmed receive/loss counters in the generated build sources.

## Automated checks

| Check | Result | Evidence |
|---|---|---|
| Full Swift suite with hardware tests enabled | 62 passed: 11 core, 4 presentation policy, 3 statistics preferences, 5 statistics/shortcut, 19 host, 9 transport, 4 timing, 7 video | `artifacts/stream-statistics-tests.log` |
| Native bridge and actual patched RTP packet paths under ASan/UBSan | Passed; eight RTP scenarios, real FEC recovery, bounded timing windows and concurrent snapshots | `artifacts/transport-telemetry-asan.log` |
| Same native paths under TSan | Passed; 100,000 receive updates and 100,000 metadata updates racing readers | `artifacts/transport-telemetry-tsan.log` |
| Dependency preparation | 3 passed, including patch isolation/integrity | `artifacts/stream-statistics-dependency-tests.log` |
| Display publication harness | 6 checks passed on the updated MacStreamSurface source | `artifacts/display-publication.json` |
| Signed app build and strict verification of both bundles | Passed; identical executable hashes | `artifacts/stream-statistics-build.log`, `artifacts/stream-statistics-bundle.json` |

Shortcut regression coverage includes repeats, key-up after modifier release, and modifiers pressed while an ordinary forwarded key is already repeating, so a remote key is not left held. Timing tests cover absent/invalid samples, zero-valued valid timings, counter resets, rolling windows, clock calibration, duplicate presentations and paired estimates. SwiftUI publishes changed visible rows at four updates per second, independently of frame callbacks.

## Live checks on the final executable

The existing paired Desktop session resumed successfully. Control–Option–Shift–S showed and hid Simple statistics while playback continued. The Detailed panel displayed live values at the left, right and center positions. Changing detail/position and pressing Done caused no reconnect prompt. Control–Option–Shift–Z released capture, and clicking the video recaptured it. From captured input, Control–Option–Shift–Q returned directly to the paired library, which still showed “App running” and “Resume Desktop.” No remote quit was requested.

The requested profile remained Native 3440 × 1440, Match Display 165 Hz, manual 350 Mbps, HEVC, HDR On, Fit, Relative Mouse and full-screen launch. The observed Simple/Top Left preferences were restored after checking the other positions. Full-screen video covered the display and the statistics panel stayed above it without taking input focus.

One final-build Detailed/Top Center snapshot showed actual received 3440 × 1440 at 16.2 FPS, host processing 3.60/8.70/3.98 ms, RTT 1.00/1.00/1.00 ms, frame-arrival jitter 3.93 ms, 0/8,228 frames lost, decode 1.32/4.10/2.17 ms, first-packet-to-presentation 14.19/82.97/26.89 ms, and estimated host-to-display 28.52 ms. These are a single live UI observation, not a controlled benchmark or proof of requested 165 FPS throughput. Other snapshots changed as expected. No artificial packet loss was injected into the real host connection; positive loss cases are covered in the native packet tests.

The host-to-display estimate adds half the observed control-channel RTT to the mean of frame-paired host processing plus client first-packet-to-drawable-presentation durations. It assumes approximately symmetric transit. Timing windows have different valid sample populations, so the estimate must not be reconstructed by adding unrelated row averages. The protocol does not supply synchronized host/client clocks, and drawable presentation is not a physical scanout or photon measurement. Network jitter is RTP-relative frame-arrival variation, which also includes host pacing and receive scheduling.

The earlier clean export/replay baseline, pairing follow-up and full-screen/deadlock report remain archived. No new performance comparison, optical latency measurement, physical HDR/audio/input qualification, long soak or other Apple device validation is claimed. [validation-summary.json](validation/validation-summary.json) records current evidence and source hashes; [the acceptance matrix](acceptance-matrix.md) retains the outstanding release gates.

## Panel layout follow-up

The panel now keeps labels and values on a single baseline, with consistent left/right alignment and more horizontal room. The stacked-row fallback and explanatory footer are removed, along with the unused footer state and jitter footnote marker. Definitions and timing order are in [Reading the panel](stream-statistics-implementation.md#reading-the-panel). Each metric remains a separate accessibility element containing its label and value.

Five existing statistics tests passed and the app rebuilt with a valid signature. Both Simple and Detailed layouts were inspected with live HEVC/HDR Desktop values on the final `e1afdc8f4668b656883f6acd922764a03aa6e0fb5864f2d37c1e0f523f49af11` build: all rows stayed on one line, no footer appeared, and the accessibility tree exposed each metric once. Settings were restored to Simple/Top Left and the app was left in the paired library after local disconnect. Stream quality was preserved. This is a layout check, not a new transport or performance qualification; the earlier 62-test full-suite result remains scoped to its recorded build.

The updated app is `.build/Swiftlight.app`, with an identical signed copy at `.build/Verified/Swiftlight.app`. Logs are `artifacts/statistics-layout-tests.log`, `artifacts/statistics-layout-build.log` and `artifacts/statistics-layout-bundle.json`. [statistics-layout-validation.json](validation/statistics-layout-validation.json) records this follow-up separately from the original statistics run.

## Current-frame Simple statistic

Simple now includes **First packet → display** as the latest confirmed distinct frame's latency, sampled every five seconds and held between samples. The selected frame has the greatest actual presentation timestamp, so ring wrap and callbacks arriving out of order cannot select an older frame. Missing timing on the latest frame or a presentation older than five seconds yields unavailable at the next refresh. Detailed keeps its rolling min/max/average; the new Simple value is not an average.

The final signed build is `554b318ad7cc597c758201c85d324753e4b84eac77b30d5bb4c0ae84d5af324c`, available in `.build/Swiftlight.app` and `.build/Verified/Swiftlight.app`. Ten focused statistics/timing tests passed, including current-frame selection, expiration, missing data and Simple/Detailed formatting. Live Simple UI observations showed the row updating with individual values while playback continued; exact timer cadence was not measured. Existing settings were preserved and the app returned to the paired library after local disconnect. See [current-presentation-validation.json](validation/current-presentation-validation.json) for scoped evidence. The earlier long-window-average candidate was superseded before live validation.
