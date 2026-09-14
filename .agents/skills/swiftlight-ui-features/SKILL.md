---
name: swiftlight-ui-features
description: "Add or change Swiftlight UI features for macOS, iOS, iPadOS and tvOS in SwiftUI screens or the live streaming surface. Check current platform-specific Apple Human Interface Guidelines, keep SwiftUI-owned UI in SwiftUI, and make in-stream additions user-toggleable, off by default, and subject to measured frame-to-display latency checks. Use for UI implementation, not backend-only changes."
---

# Swiftlight UI Features

Implement the requested UI feature within the existing app architecture. Read the repository's [AGENTS.md](../../../AGENTS.md) and relevant source first. User instructions take precedence over this skill; do not broaden a feature request into a redesign, rewrite, dependency migration or release task.

## Identify the platform and UI surface

This skill covers macOS and the developing iOS, iPadOS and tvOS clients. Determine which platforms the request affects and inspect their actual app targets, source ownership, deployment versions and available implementations. Read the relevant rows in [platform UI guidance](references/platform-ui.md). Package platform declarations alone do not establish an implemented client; do not invent target names or expand a feature into an unrequested platform port.

| Surface | Implementation rule |
| --- | --- |
| SwiftUI-owned app screens, including library, pairing and Settings | Write new and modified views, layout, controls and state bindings in SwiftUI on every platform. Reuse existing SwiftUI components and system controls with platform-appropriate navigation and interaction. Do not introduce AppKit, UIKit or web UI to implement these screens. |
| Additional visuals during live streaming | Follow the streaming rules below and read [streaming UI implementation and measurement](references/streaming-ui.md). Prefer the existing Metal overlay path used by statistics. |
| A feature spanning both surfaces | Put configuration and ordinary app controls in SwiftUI; integrate the in-stream visual into the streaming presentation path. Share feature state without publishing individual frames through SwiftUI. |

Keep necessary platform integration in narrow adapters: AppKit on macOS and UIKit/Metal hosting, input, focus or accessibility adapters where required on iOS, iPadOS or tvOS. Preserve existing adapters and extend them only as needed; they are not a reason to implement SwiftUI-owned screens in AppKit or UIKit. Share feature state and rendering contracts without forcing identical layouts or copying macOS dependencies into other clients.

## Check current Apple guidance for each UI task

Before making design or API choices, browse Apple's current Human Interface Guidelines and the documentation for the actual SwiftUI controls/APIs being used. Read the relevant pages, not just search snippets; this skill and dated repository notes are not substitutes for a fresh check.

Start with the applicable parts of:

- The affected platform's HIG entrypoint and input guidance in [platform UI guidance](references/platform-ui.md), plus the affected component's HIG page. For shared UI changes, check each affected platform.
- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) for labels, focus, keyboard access, contrast and adaptable presentation.
- [Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards) when adding or changing shortcuts.
- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials) and [SwiftUI custom Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views) when styling surfaces.

Use official Apple sources. If a page exposes only a JavaScript shell, use a browser or Apple's linked Markdown/DocC representation to read the content. Record the pages consulted, access date and the decisions they informed in the task's review notes. Avoid copying Apple's documentation into the skill or adding transient research notes to the repo unless they help maintain the feature.

Use native SwiftUI controls, semantic styles and the existing `GlassStyle` where appropriate. Check API availability against the deployment target and preserve supported-OS and accessibility fallbacks. Do not apply glass everywhere or move glass/composition surfaces over the stream solely to imitate the app's surrounding chrome.

If current Apple guidance cannot be retrieved, state the missing verification, continue independent implementation/checks where possible, and do not claim that current HIG compliance was verified.

## Implement the feature

- Use Xcode as the primary app build/run path and follow the [platform build and verification guidance](references/platform-ui.md#build-and-verify-the-affected-platforms). Keep app source/resource membership correct in the owning Xcode target; a SwiftPM build alone does not verify app membership or a platform client.
- Keep SwiftUI-facing state on `@MainActor`. Reuse existing settings, input and lifecycle helpers. Maintain accessible names, values and platform-appropriate touch, keyboard, pointer, remote and focus behavior, including accessibility metadata for any Metal-drawn controls or information.
- Keep technical implementation and metric explanations in the relevant documentation; expose only information that helps the person using the feature.

For every new or modified additional in-stream UI element:

1. Provide a user-controlled show/hide toggle through a keyboard combination **or** a Settings option. On iOS/iPadOS, provide a touch-accessible in-app Settings control; on tvOS, provide a Settings control reachable with the remote and focus navigation. An optional keyboard or controller must not be the only way to toggle these clients' UI. Keyboard, controller or other convenience actions can supplement Settings; all routes must operate on the same state. On macOS, either a shortcut or Settings suffices. Make the control discoverable while the addition is hidden and test both directions.
2. Default the addition to **off/hidden** when the user has not opted in, including a missing setting during migration. Do not automatically open extra windows or panels on connection, reconnect or an update. Preserve intentional saved choices where persistence is part of the feature; do not reset unrelated user preferences.
3. Make hiding effective: remove its visible content and hit targets, cancel stale UI publication, and stop feature-only rasterization, uploads, animation and polling when unnecessary. A transparent view is not sufficient. Preserve the underlying stream and existing features.
4. Do not regress frame-to-display latency with the feature hidden **or visible**. Reusing the statistics panel's Metal rendering approach is the preferred design, not proof of zero cost. Follow the reference's baseline/off/on comparison before making a no-regression claim.

For keyboard shortcuts, follow current Apple conventions and reuse `StreamShortcuts` where applicable. Keep local UI input separate from forwarded gameplay input across keyboard, touch, remote and controller adapters; prevent consumed actions, repeats or unmatched releases from leaking to the host. Preserve system gestures/buttons, held-input cleanup and capture/focus behavior. For presentation-only toggles, update the presentation state without disrupting the streaming session.

## Verify and report

Build each affected Xcode app target and run focused tests for the changed state/defaults, settings, input, renderer or lifecycle. Use the repository's SwiftPM/native/hardware checks where applicable to that platform. Inspect the launched UI using the platform verification matrix, including relevant appearance, accessibility, size/orientation and lifecycle states. Do not substitute a preview or successful compile for the affected live flow.

For a streaming feature, verify first-use hidden state, enable/disable, existing statistics coexistence, reconnect/teardown and the measured latency comparison in the reference on each affected platform/device class. Simulator results or a Mac measurement do not establish iPhone, iPad or Apple TV streaming performance. Treat a repeatable latency increase as a failed acceptance check to fix; default-off does not excuse a regression when enabled. Do not silently invent an acceptable latency budget.

Report the affected platforms, implemented surface and user control, default behavior, Apple sources checked, build/test/visual results, and measured latency results with their limits. If a platform target, live host, device/display or timing evidence is unavailable, finish the independent work and identify that platform's unverified acceptance checks. Do not describe use of Metal, simulator/offscreen replay or missing samples as a passed no-regression result. Creating or updating this skill alone does not require an app build or a live stream.
