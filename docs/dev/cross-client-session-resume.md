# Cross-client session resume follow-up

Status: deferred on 2026-09-13. Keep the current resume behavior while reliable session-origin detection is unavailable.

## Observed behavior

A phone starts Desktop and remains connected. Joining Desktop from Swiftlight on a Mac resumes the host's running application; the Mac can inherit the phone's host display layout and resolution. Swiftlight sends its configured width, height, and frame rate, but those stream parameters do not guarantee that the host changes its display while another client is connected. Host display dimensions and encoded stream dimensions should be measured separately when investigating this.

## Reference behavior

The reviewed clients resume an already running application and send their own stream parameters. Their launch/resume paths do not distinguish which client originally launched the application or offer a session-origin-specific restart prompt:

- [Moonlight Qt](https://github.com/moonlight-stream/moonlight-qt/blob/f743c23663bcd01059b620b823629e0afcb3dde8/app/streaming/session.cpp): `Session` selects `resume` when an application is running; `app/backend/nvhttp.cpp` sends the requested mode.
- [Moonlight iOS](https://github.com/moonlight-stream/moonlight-ios/blob/85af0f75622bb2636481afda8b0fc5cc33d5956e/Limelight/Stream/StreamManager.m): `StreamManager` resumes a busy host; `Network/HttpManager.m` supplies the mode for both launch and resume.
- [VoidLink](https://github.com/The-Fried-Fish/VoidLink-previously-moonlight-zwm/blob/5d3985e7d2c75293082885a2e83006efebb1a213/VoidLink/Stream/StreamManager.m): the corresponding stream and HTTP managers follow the same pattern.

In the host implementations reviewed on 2026-09-13, [Sunshine's resume handler](https://github.com/LizardByte/Sunshine/blob/master/src/nvhttp.cpp) only invokes display configuration when there are no active streaming sessions. [Apollo's resume handler](https://github.com/ClassicOldSong/Apollo/blob/master/src/nvhttp.cpp) additionally checks that the running process is not using a virtual display. This is consistent with retaining the phone's display configuration during simultaneous connections; it is source evidence, not a captured host-side trace of the reported case.

The normal authenticated server-info responses expose the running application and busy/idle state, but do not expose a reliable originating-client identity and per-launch session identifier. Apollo's `currentgameuuid` identifies the application, not a particular launch or its originating client.

## Deferred product behavior

The requested follow-up is to offer **Resume Session**, **Quit and Start New**, and **Cancel** only when the running session was started by another client. Sessions started by this Swiftlight client should resume without that prompt. Another Moonlight installation on the same Mac may have a different client identity, so device identity and client identity must not be conflated.

Remembering the last application Swiftlight launched would only be a heuristic. The host or application could restart, or another client could stop and restart the same application between polls, without changing its application ID. Do not add that heuristic or claim an unknown session belongs to another client. No new prompt or automatic restart is implemented by this change.

Revisit when a supported host can provide trustworthy session-origin information and a session generation that changes on each launch. A host-reported indication that the authenticated client started the session could avoid exposing other clients' identities; this is a proposed capability, not an existing protocol field. Define behavior for hosts without that capability before implementing the prompt.

## Implementation and acceptance criteria for a future change

- Recheck session identity and generation immediately before acting on a confirmation. A changed session requires a new decision; an application ID alone is insufficient.
- Explain that **Quit and Start New** closes the running host application, disconnects its streams, and may lose unsaved progress. Require the user's explicit choice before quitting.
- Implement an explicit same-application restart path: cancel, verify the old application has quit, then launch with the Mac's settings. The current [`HostClient.prepareApplication`](../../Sources/shared/SwiftlightHost/HostClient.swift) path deliberately resumes the same application.
- Cover locally started sessions, sessions started elsewhere with the other client connected or disconnected, unknown origin, client/host relaunch, same-application replacement between polls, changed confirmations, and denied quits. A failed quit must never launch the replacement.
- Validate real simultaneous phone/Mac connections and record host display configuration, requested stream mode, encoded dimensions, and playback after both resume and restart. Fixture tests cannot establish display reconfiguration behavior.

The existing [remote session controls](host-manual-test.md#remote-session-controls) remain available: quit from the running application's context menu, or quit and start when selecting a different application.
