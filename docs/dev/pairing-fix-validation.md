# Pairing follow-up validation

On 2026-09-12, Swiftlight was rebuilt and relaunched against the user's Vibepollo host over its Tailscale DNS address. The native window showed **Paired** and loaded the authenticated application library (48 launch buttons). The user's existing pairing identity survived relaunch. The PIN exchange was completed by the user; this follow-up verified the resulting saved pairing and authenticated library access. No stream was launched during this validation.

## Findings and fixes

- The initial tailnet request failed with `NSURLErrorAppTransportSecurityRequiresSecureConnection` (`-1022`). GameStream bootstraps arbitrary user-entered hosts over HTTP. `NSAllowsLocalNetworking` only covered the local-name cases, so the app now declares `NSAllowsArbitraryLoads` without the overriding local-network exception. Authenticated requests still require the exact server certificate pin and client identity; redirects remain rejected. See  [host-protocol-details.md](host-protocol-details.md) for the Apple ATS reference and trust boundary.
- The asynchronous `URLSession.bytes` path did not deliver the required authentication challenges to the session delegate. It now supplies the delegate explicitly and handles task-level challenges. A real loopback mutual TLS regression requires the expected client certificate and verifies rejection of a changed server pin. Certificate rejection is classified before generic request cancellation.
- A new host address now resolves existing trust by the host ID learned during bootstrap. An authenticated host that has revoked pairing cannot be reported as successfully paired. Explicit unpair/re-pair recovery remains available, and refresh/selection cannot interrupt an in-progress pairing operation.
- Display geometry publication caused a SwiftUI/AppKit feedback loop. Display and headroom changes are now deduplicated and coalesced, while actual resize/screen changes continue to publish. Unchanged power statistics and stream settings no longer trigger redundant view updates.

The changes are in Swiftlight's host and app layers. The pristine `moonlight-common-c` source lock remains pinned to `62e066388f1a1b133e0bee947b9a374311a3354b`, compiled through `CStreamBridge` with the existing three targeted patches. No additional common-c or decoder patch was needed for this repair.

## Executed checks

| Check | Result |
|---|---|
| `scripts/build-app.sh` | PASS; native app rebuilt and signed |
| `SWIFTLIGHT_RUN_HARDWARE_TESTS=1 swift test --disable-sandbox --manifest-cache none` | PASS; 39 tests: 11 core, 15 host, 7 transport, 6 video; no failures |
| `python3 scripts/validate-display-publication.py` | PASS; six publication lifecycle checks against production source |
| Running macOS UI after relaunch | Paired status and authenticated application library visible |
| Read-only idle process samples | Approximately 99% CPU before the publication fix and 0.1% afterward; the later main-thread stack waited in the normal AppKit run loop |
| Copied app signature and plist | PASS; strict signature verification and plist validation |

The CPU readings are short idle observations, not a streaming performance benchmark. The display-publication helper opens no window and does not measure CPU; the live process samples are separate evidence.

The current bundle is `.build/Verified/Swiftlight.app`, binary SHA-256 `cc995ee93ca53e54de04d4cda66a429beb65da9bc2e9708180d9ea8ef977c3d1`. The same binary is running from `.build/Swiftlight.app`. Machine-readable results and production source hashes are in [validation-summary.json](validation/validation-summary.json). Local logs are `artifacts/pairing-fix-build.log`, `artifacts/pairing-fix-tests.log`, `artifacts/display-publication.json`, and `artifacts/pairing-fix/`.

The earlier clean-export suite, eight replay fixtures, and sanitizer results are preserved separately in [validation-baseline-2026-09-12.json](validation/validation-baseline-2026-09-12.json). They were not all rerun for this follow-up. Live launch/resume/quit, streaming audio/input, physical HDR, network fault recovery, and sustained latency/thermal measurements remain open in the [acceptance matrix](acceptance-matrix.md).
