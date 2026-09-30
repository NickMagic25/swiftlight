# Streaming UI implementation and measurement

Read this reference only for additional UI drawn in or over the live streaming surface on macOS, iOS, iPadOS or tvOS. Its purpose is to preserve the user's clean default view and frame-to-display latency while adding the requested feature. Combine it with the affected rows in [platform UI guidance](platform-ui.md).

## Reuse the production presentation path

Inspect the current implementations; these paths are starting points, not frozen copies of their behavior. The app-side examples below come from the macOS client. Find the corresponding mobile/TV surface, state, input and accessibility adapters as those implementations land; do not compile `MacStreamSurface` or other AppKit-specific code into those clients:

| Source | Reuse or preserve |
| --- | --- |
| [ClientModel.swift](../../../../Sources/desktop/ClientModel.swift), [SettingsView.swift](../../../../Sources/desktop/SettingsView.swift) | User-visible state, settings bindings and teardown. |
| [StreamShortcuts.swift](../../../../Sources/shared/SwiftlightCore/StreamShortcuts.swift), [SwiftlightApp.swift](../../../../Sources/shared/SwiftlightApp/SwiftlightApp.swift) | Existing shortcut handling and command discovery. |
| [MacStreamSurface.swift](../../../../Sources/desktop/MacStreamSurface.swift) | Visibility updates, cancellable raster work, revision checks, accessibility elements and bounded redraw signals. |
| [StatisticsOverlayRasterizer.swift](../../../../Sources/shared/SwiftlightApp/StatisticsOverlayRasterizer.swift) | Off-main-thread text rasterization when displayed content changes. |
| [VideoOverlayBitmap.swift](../../../../Sources/shared/SwiftlightVideo/VideoOverlayBitmap.swift), [MetalVideoRenderer.swift](../../../../Sources/shared/SwiftlightVideo/MetalVideoRenderer.swift) | Bounded bitmap data, cached texture upload and overlay drawing in the video's existing render pass/drawable. |

Prefer extending this shared mechanism for additional in-stream visuals. The current `setOverlay` interface represents one overlay: do not simply replace the statistics texture with the new feature. Support independent visibility and correct coexistence, generalizing or composing the bounded overlay representation only as needed for the request.

Reuse platform-neutral renderer, bitmap and timing contracts where supported. Keep platform-dependent rasterization, scale, input, focus and accessibility at the edges, verifying API availability. If a client has not connected this overlay path yet, integrate only the necessary adapter within the requested scope; do not substitute per-frame SwiftUI publication or an independent renderer/decoder. The macOS implementation is a model to inspect, not evidence that mobile/TV integration already works.

- Reuse cached content between changes. Keep rasterization off main/media callbacks and do not create an image, upload unchanged textures or publish SwiftUI state for each decoded frame.
- Draw through the existing video pass and drawable where appropriate. Avoid extra windows, SwiftUI glass layers, render passes, drawable acquisition or presentation queues for an informational overlay. If a different implementation is necessary, explain why and subject it to the same performance gate.
- Preserve GPU admission bounds and buffer/texture ownership through completion. Do not add synchronous GPU waits, blocking callback locks or CPU copies of video frames.
- Treat hidden as inactive for feature-only work. Cancel outstanding UI tasks, reject late results after hide/teardown, and remove hidden accessibility/hit-test/focus targets. Restore focus appropriately when an active control disappears. Keep shared telemetry required by other features running.
- Preserve scale, safe-area placement, HDR/SDR color behavior and readable text. Metal drawing must retain matching accessibility semantics and any required interaction. Use semantic accessibility values without adding a visible duplicate overlay.

Read [video ownership](../../../../docs/dev/video-lifetime.md), [statistics implementation](../../../../docs/dev/stream-statistics-implementation.md) and [diagnostic schema](../../../../docs/dev/diagnostic-exports-schema.md) for the affected contract.

## Measure the requested no-regression property

Use [benchmarking](../../../../docs/dev/benchmarking.md) and [latency debugging](../../../../docs/dev/stream-latency-debugging.md). The [previous Metal statistics comparison](../../../../docs/dev/statistics-metal-overlay-2026-09-13.md) illustrates drift and measurement limits; it is not performance evidence for a new feature or proof that Metal overlays have zero latency cost.

Run a separate matched comparison on representative physical devices for each affected platform/device class. Use the same device and OS for all conditions within a comparison, with comparable thermal/power state and fixed orientation/window size. Mac, simulator and offscreen results do not establish displayed-frame performance on iPhone, iPad or Apple TV. Confirm that the client's timing/export path implements the needed schema and presentation callbacks; where it does not, add the required bounded instrumentation within scope or report missing evidence without inventing measurements.

1. Preserve or capture an unmodified baseline before making presentation changes. Use a separate checkout/build output if needed; do not discard current work to obtain it.
2. Compare **baseline**, **modified build with feature off**, and **modified build with feature on**. Repeat/interleave equal-duration trials after warmup, including a return to baseline/off to expose drift. Use at least three comparable trials per condition, following the repository benchmark procedure. Exclude windows that mix toggle states or contain warmup.
3. Keep the host/encoder/scene, stream request, actual codec/resolution/FPS, display/refresh/HDR, network route, pacing/VSync/drawable settings, input capture and other overlays fixed. Keep profiling/HUD overhead identical or absent. Record commit, build configuration, toolchain, environment and feature visibility with each capture. Never improve the comparison by changing stream quality or presentation policy.
4. Use same-frame, calibrated timing with a positive **confirmed drawable presentation**. Where the client supports the existing timing path, `firstPacketToPresentationMilliseconds` is the primary arrival-to-display proxy; state that its start is first-packet receipt. Verify equivalent timing semantics before comparing new platform exports. Supplement it with supported frame-selection/decoder-to-presentation stages as needed. GPU completion, a predicted display deadline, decode time and offscreen replay do not measure displayed-frame latency or physical scanout.
5. Analyze bounded steady-state exports with [analyze-stream-latency.py](../../../../scripts/analyze-stream-latency.py). Record sample counts, missing/unconfirmed timings, mean and p50/p95/p99, presentation cadence, skips/drops, GPU work and queue high-water marks. Use equal populations/windows; a faster average with worse tails or fewer confirmed frames does not establish no regression.
6. Compare off against baseline for hidden overhead and on against off/baseline for visible overhead. Investigate and fix a repeatable increase; do not accept one merely because the UI is optional. Report variation and uncertainty. If captures are too noisy, incomplete or missing actual presentation, collect better evidence where possible and leave the performance result unverified.

From the repository root, an example analysis command is:

```sh
python3 scripts/analyze-stream-latency.py \
  artifacts/ui-feature/baseline.json \
  artifacts/ui-feature/feature-off.json \
  artifacts/ui-feature/feature-on.json \
  --output artifacts/ui-feature/analysis.json
```

The inputs are actual exported captures in the analyzer's supported schema, not generated placeholders. Confirm export compatibility for the target client first. Repeat the analysis for additional trials and keep different devices/platforms in separate result groups. This command analyzes existing data; it does not conduct live trials or automatically decide whether the feature passed. Keep raw captures and generated analyses in ignored `artifacts/`, and retain privacy filtering.

## Completion evidence

Record the platform/device/OS, actual Settings label or shortcut and input method, default and saved-choice behavior, Apple pages consulted and date, Xcode scheme/destination/build, focused tests, visual/accessibility checks and artifact locations. For streaming latency, identify each condition and compare its sample counts, p50/p95/p99 and observed variation. State each platform's result separately: whether a regression was detected or whether available evidence was insufficient. Do not promise universal zero latency from a finite test.
