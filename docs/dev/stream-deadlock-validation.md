# Desktop stream deadlock diagnosis

Status: the diagnosed lock inversion is corrected. The targeted regression, final 48-test suite, and live Desktop checks passed. The final native full-screen viewport is 3440 × 1440 on the tested external display. Sustained and broader display qualification remain separate.

## Observed failure

After the user launched Desktop, Swiftlight beachballed while its overlay reported decoded 3440 × 1440 HEVC 10-bit output. Read-only process metadata identified PID `59828`, launched on 2026-09-12 at 19:32:48 EDT, running `.build/Verified/Swiftlight.app/Contents/MacOS/Swiftlight`. CPU usage was 12.3% immediately before sampling.

At 19:33:32 EDT, this command collected a three-second stack-only sample:

```sh
sample 59828 3 10 -file /private/tmp/swiftlight-59828-stream-sample.txt
```

The local raw trace is `/private/tmp/swiftlight-59828-stream-sample.txt`. It contains 267 observations of each affected thread. The following source line numbers refer to the sampled build and may shift in the corrected source.

| Thread | Stack in every observation | Evidence in raw trace |
| --- | --- | --- |
| Main | `MacStreamView.metalDisplayLink` → `MetalVideoRenderer.render` → `encode` line 198 → `CAMetalDrawable.addPresentedHandler` → Core Animation unfair-lock wait | Lines 24–54 |
| Core Animation presentation callback | `CAMachPortUtilReplyQueue` → `CAMetalDrawable.didPresentAtTime` → renderer presented-handler line 200 → renderer mutex wait | Lines 59–74 |

## Cause

`MetalVideoRenderer.encode` held the renderer mutex while calling `addPresentedHandler`. Core Animation concurrently invoked an earlier presented handler while holding its drawable lock; that handler tried to acquire the renderer mutex. The two threads waited for each other's lock. The main thread could no longer process window events, producing the beachball.

Transport continued making progress during the hang. The sample captured completed video packets being queued, decoder submissions, and `LiCompleteVideoFrame` calls. It did not show the main thread waiting on transport cancellation, input locks, the audio ring, or Keychain. Audio threads were in ordinary receive/queue/device waits; this does not verify audible playback.

## Correction and executed checks

Encoding/cache serialization now uses a different lock from the bounded metrics. Drawable handler registration, presentation, and command commit occur after releasing the encoding lock. No Core Animation or Metal call runs under the metrics lock; presented handlers read the drawable timestamp before taking that lock. Capacity reservation, command enqueue order, and retained frame/CoreVideo texture ownership through GPU completion are preserved. An independent source review found no blocking lock-order or ownership regressions.

- `testDrawableCallbackCanFinishDuringHandlerRegistration` passed under Metal API validation at 19:39:13 EDT in 0.066 seconds; see `artifacts/drawable-lock-regression.log`. A synthetic drawable synchronously waits, with a one-second bound, for a concurrent presented callback during registration. This deterministically exercises the opposing lock order while production GPU encoding, commit, and completion run. Physical presentation is intentionally omitted and is not claimed by this test.
- The final full suite passed: 11 core, 4 presentation-policy, 19 host, 7 transport, and 7 video tests, totaling 48 with no failures. The earlier renderer-only follow-up passed 44; the four additions cover Keychain caching and invalidation. See `artifacts/stream-fix-tests.log`. This run is separate from the earlier eight-fixture clean offline baseline.
- With the first renderer-fixed build, live UI inspection confirmed Desktop streaming with decoded 3440 × 1440 HEVC 10-bit output without the previous hang, input capture/release, and local disconnect returning to the library and native window. This is a short functional observation, not a sustained performance, physical HDR, or comprehensive remote-input qualification.
- Later windowed playback on binary `d9b141c4fa5f0eecd666386153f4a1346cf0fb8a0ada1e1847cbabe3620cd709` visibly reported decoded 3440 × 1440 output and a 1720 × 1409 viewport without the hang. A three-second sample at 19:45:10 EDT on PID `65559` found 254 of 259 main-thread samples in normal run-loop wait and five in the display link, with decoder submissions progressing. The prior opposing-lock cycle was absent. See `artifacts/stream-fix-live-result.json` and `artifacts/stream-fix-live-sample.txt`. These observed dimensions and short sample do not complete geometry qualification or rule out future deadlocks.

## Final presentation and signing check

The final developer-signed binary is `ca9237035a84fd57f50a4fc753d47aa1ee03a7c5c22e8e1b17c52ae23aeb852c`. At 20:19:25.550 EDT, PID81183 logged screen, native full-screen window, content, view, layer and drawable all matching **3440 × 1440**, with scale1 and zero safe-area insets. See `artifacts/fullscreen-display-final.json` and `.log`. The native delegate negotiates complete-screen content size and hard-hides the menu bar/Dock. UI inspection showed edge-to-edge video, requested/decoded3440×1440 HEVC10-bit, requested165FPS/manual350Mbps, responsive capture controls, and subsequently the restored paired library with toolbar and window buttons. The user initiated and ended this final stream while the agent observed. Requested FPS/bitrate are not actual performance measurements.

Ten isolated window-lifecycle groups passed, including cancellation/timeout recovery, delegate forwarding and restoration, and presentation option cleanup. Nineteen packaging checks passed. The build now uses a stable Apple Development identity locally; the two successive signed builds have the same designated requirement. The final app reopened the existing paired library. That establishes successful access, not a prompt-free migration from earlier ad-hoc builds. Pin caching avoids repeated successful Keychain reads in a process and preserves explicit unpair/forget invalidation. See `signing.md` and `artifacts/signing-identity-comparison.json`.

## Remaining verification

Native full-screen and windowed launches, capture/release, and library toolbar restoration have been observed. The initial full-screen checks exposed a separate 30-point window-size reduction: screen 3440 × 1440 but NSWindow, content, layer, and drawable all 3440 × 1410. See `artifacts/fullscreen-display-geometry.log`. This is window geometry, separate from the corrected drawable lock inversion. Sustained visible playback, repeated close/reconnect/cancel/sleep transitions, AV1 interoperability, audio/input/haptics, and display/pacing measurements remain separate release checks.

The original stack-only diagnostic did not interact with the UI or inspect credentials. Subsequent live checks resumed Desktop with the user’s authorization and disconnected locally. The earlier offline Metal readback passes did not exercise this live drawable callback interleaving.
