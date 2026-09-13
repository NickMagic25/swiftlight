# Audio settings and Spatial Audio

Swiftlight's initial macOS audio options separate the audio mix requested from the host from its local output mode. Open **Settings → Audio**, choose the options below, then **Save for This Computer** or **Use as Global Defaults**. Reconnect to apply changes. Existing saved settings default to Stereo, Direct and host playback disabled while retaining their other preferences.

| Setting | Choices and behavior |
| --- | --- |
| Audio channels | Stereo (2 channels), 5.1 Surround (6), or 7.1 Surround (8). This requests the source mix from the host; it does not synthesize additional game channels. |
| Audio output | Direct uses the macOS default-output Audio Unit. System Spatial Audio sends multichannel PCM to Apple's sample-buffer renderer and permits multichannel spatialization. |
| Play audio on host | Requests audio playback on the host as well as the client. Disabled by default; the host determines how its local playback request is applied. |

System Spatial Audio is available in Swiftlight's picker only with 5.1 or 7.1 selected. Changing to Stereo selects Direct. Runtime configuration also forces Direct for stereo, including inconsistent or partial saved preferences. Connecting AirPods does not change the requested channel count; two physical headphone channels can still receive a system-rendered surround mix.

## Choose where the spatial mix is rendered

For a game with a headphone, binaural or HRTF mode that you want to use, set its audio output to that mode and select **Stereo + Direct** in Swiftlight. The game has already rendered the directional cues into two channels.

For client-side surround virtualization, configure the host's streaming audio device and the game for **5.1 or 7.1 speakers**, select the matching channels in Swiftlight, and choose **System Spatial Audio**. Disable the game's headphone/binaural mix for this configuration. Requesting surround alone does not ensure that a game outputs surround: verify the host device and each game's speaker settings with a channel-isolation recording or the game's test sounds.

For a physical surround speaker system, choose the matching surround configuration and **Direct**. macOS and the output device must be configured for the appropriate speakers. Direct downmixes locally when the output has fewer physical speaker channels, without renegotiating the host mix. Verify every channel on the actual output; selecting 7.1 cannot turn a stereo device into eight physical speakers.

## AirPods and Apple's controls

Connect compatible AirPods and begin a surround stream with System Spatial Audio selected. Open the **AirPods menu in the macOS menu bar** and inspect the Spatial Audio controls. Where supported, **Off** disables spatial playback, **Fixed** enables it without head tracking, and **Head Tracked** enables tracking. The system remembers supported app preferences. Availability depends on the Mac, AirPods, macOS and content; Swiftlight's setting only permits the renderer to spatialize. Apple documents Mac support and these controls in its [AirPods guide](https://support.apple.com/guide/airpods/control-spatial-audio-and-head-tracking-dev00eb7e0a3/web).

Swiftlight does not read or claim an active Head Tracked or Personalized Spatial Audio state. This initial implementation uses Apple's system renderer and does not add a custom `AVAudioEngine`/environment-node renderer, motion polling, a head-pose entitlement or spatial-profile entitlement. Personalization and head-tracking behavior on this app still require physical verification.

This is channel-based surround playback. Moonlight audio contains a mixed channel bed, not each game sound's position or audio objects. No Dolby Atmos object passthrough, reconstructed height channels or game-object positioning is claimed.

## PCM layout, timing and lifecycle

The channel count is carried through host launch/resume, common-c negotiation, Opus decoding and output. Swiftlight retains the Opus mapping delivered by common-c. Its documented PCM order is:

| PCM index | Speaker | Configurations |
| --- | --- | --- |
| 0 | Front left | Stereo, 5.1, 7.1 |
| 1 | Front right | Stereo, 5.1, 7.1 |
| 2 | Center | 5.1, 7.1 |
| 3 | LFE | 5.1, 7.1 |
| 4 | Back left | 5.1, 7.1 |
| 5 | Back right | 5.1, 7.1 |
| 6 | Side left | 7.1 |
| 7 | Side right | 7.1 |

The Apple PCM format includes an explicit channel layout so center, LFE, rear and side channels are not interpreted as a different order. The system mode preserves the multichannel mix until Apple's renderer; it does not pre-downmix it to stereo. The shared Opus decoder retains packet-loss concealment and runs off the realtime output callback.

System mode attaches `AVSampleBufferAudioRenderer` to `AVSampleBufferRenderSynchronizer` before queuing audio, constructs timestamped PCM sample buffers and permits `.multichannel` spatialization. The separate Metal video pipeline remains in place. Apple documents this contract in [AVSampleBufferAudioRenderer](https://developer.apple.com/documentation/avfoundation/avsamplebufferaudiorenderer) and [allowedAudioSpatializationFormats](https://developer.apple.com/documentation/avfoundation/avsamplebufferaudiorenderer/allowedaudiospatializationformats).

Both modes use a 2,048-frame PCM ring (42.67 ms at 48 kHz). System mode groups PCM into 960-frame (20 ms) sample buffers. Before playback it collects preroll while the synchronizer is paused. Its minimum preroll comes from public Core Audio output-device latency, stream latency, safety offset and buffer-size properties, rounded to whole batches with an 80 ms minimum. Playback starts when that route-derived floor is buffered; Apple's `hasSufficientMediaDataForReliablePlaybackStart` value is recorded for diagnostics and does not gate playback. Once playback resumes, the running queue target is the accepted preroll plus one 20 ms batch, capped at 480 ms. One complete batch can extend submitted PCM to the 500 ms cap. Including the ring, the maximum software PCM bound is 542.67 ms, before additional system/device latency.

The verified AirPods stream used a 180 ms route floor and 200 ms running target. These are route-derived buffering estimates, not measured end-to-end latency. A separate probe on another default output kept Apple's sufficient-media signal false until 600 ms of queued audio, beyond Swiftlight's 500 ms submission bound. That observation applies to that probe/output, not a universal AirPods threshold, and is why the flag is diagnostic-only.

Preroll begins with received PCM, including legitimate all-zero samples; a short sound can be padded after a 20 ms collection interval. Once input has begun, network/DTX gaps may be padded with silence at realtime pace during preroll. Running playback also pads gaps while leaving one batch interval for packet collection. Missing frames count as ring underruns. This backend prioritizes reliable system playback; its latency still needs physical measurement.

System route or mode recovery requests a normal pause that preserves the synchronizer epoch, coalesces notifications, and waits for both synchronizer and renderer effective rates to acknowledge the pause. It then flushes submitted audio, discards stale ring PCM, and collects new preroll at the stopped playhead. Resume requires the route-derived preroll floor and acknowledgment that both effective rates are running. Submitted-frame accounting tracks actual unplayed sample-buffer intervals.

A host-monotonic watchdog discards incoming ring PCM after one ring duration without consumer progress, including while the renderer is backpressured or its clock is stopped. A bounded recovery timeout or renderer failure permits one replacement of the renderer and synchronizer per stream; callbacks from the retired renderer are rejected by generation. Replacement affects audio only and does not reconnect video. If recovery fails again, Swiftlight reports an explicit audio failure instead of repeatedly rebuilding or silently changing output backends. An unsupported spatial output may still play or downmix through Apple's renderer because permitting spatialization does not force the system effect.

Queue counters describe the application's buffering, not Bluetooth radio delay or the time sound reaches the listener. Neither the selected mode nor a configured queue bound establishes measured end-to-end latency. Audio playback does not automatically delay Metal presentation to hide an audio/video mismatch. See [transport ownership](transport.md#audio) for output behavior.

## Development validation

On September 13, 2026, the full integrated Swift suite passed 102 tests after the preroll and recovery rewrite (77 XCTest and 25 Swift Testing tests, no skips), with Apple hardware access. Coverage includes legacy settings migration, all audio choices, shared launch/transport channel masks, HTTPS launch and resume parameters, and preserved interleaved channel order.

Strict native validation and the AddressSanitizer/UndefinedBehaviorSanitizer offline suite passed after the rewrite, covering speaker labels, multichannel rings, downmix impulses, sample-buffer ownership/timestamps, buffering policy and recovery. All six quiet synthetic Opus paths (2/6/8 channels through both native backends) passed with actual running-state assertions, bounded queues and clean teardown. An independent forced renderer-replacement and teardown harness also passed under AddressSanitizer/UndefinedBehaviorSanitizer. Set `SWIFTLIGHT_AUDIO_SMOKE=1` when running `scripts/validate-transport-native.sh` to include real output playback; audio-device access is required. These checks establish functionality and ownership, not physical latency or audible channel placement.

## Physical acceptance matrix

The user confirmed audible **7.1 + Direct** and **7.1 + System Spatial Audio** on AirPods. On the signed build with the final preroll/recovery implementation, audio recovered and stayed audible through repeated **Fixed → Off → Head Tracked** changes. Logs showed a 180 ms preroll floor, 200 ms running target, both effective rates at 1, unmuted output and progressing real-PCM counters. The observed recoveries used normal pause/preroll/resume in the same renderer generation without replacement. This verifies audible mode-switch recovery on the tested AirPods; it does not validate channel isolation, head-pose quality, other devices or end-to-end latency.

The broader checks below remain pending. Unit tests and successful builds do not validate audible speaker placement, AirPods spatialization or physical latency. Record the Mac/macOS version, host, audio device, AirPods model/firmware, game/source, requested layout, output mode and system spatial setting for each run.

| Case | Required evidence | Status |
| --- | --- | --- |
| Stereo + Direct, built-in output and wired headphones | Correct left/right isolation; a host headphone mix stays stereo; compare against the existing stereo baseline. | Pending |
| 5.1 + Direct, matching speaker device | Isolate front left/right, center, LFE and back left/right; confirm no swap or missing channel. | Pending |
| 7.1 + Direct, matching speaker device | Repeat six-channel check and separately isolate side left/right from back left/right. | Pending |
| 7.1 + Direct, AirPods | Hear the host mix through the stereo downmix; inspect center/rear/side contribution separately. | Audible playback confirmed by user; channel isolation pending |
| 5.1 and 7.1 + System Spatial Audio, compatible AirPods | Inspect available macOS controls while playing; isolate each channel and confirm expected virtual speaker direction. | 7.1 audible playback and controls verified; 5.1 and channel isolation pending |
| System Off, Fixed and Head Tracked | Record each available state and audible behavior; turn the head left/right, test recentering, and verify the chosen state survives reconnect. | Repeated audible mode-switch recovery verified for 7.1 on tested AirPods; head-pose quality, recentering and persistence pending |
| AirPods connect/disconnect and output switching | Switch between AirPods, built-in, wired and surround outputs during audio; no crash, stale burst, accumulating backlog or lost recovery. | Pending |
| Packet loss, renderer interruption and reconnect | Confirm recovery or an explicit audio error; repeat stream start/stop and sleep/wake without old audio replay. | Pending |
| Direct versus system latency | Measure physical sound onset against the same host event and a repeatable video marker; report each route separately and measure A/V skew. | Pending |
| Sustained playback | At least 30 minutes per output mode; inspect drift, discontinuities, underrun/overflow growth and queued audio, then repeat route changes. | Pending |
| Saved preferences | Relaunch and switch computers; verify per-computer/global choices and legacy migration; reconnect with each layout. | Pending |

Do not infer a latency improvement from decoder or GPU timing. Report physical measurement equipment, event synchronization, trial count and spread, and keep the same host mix and network conditions when comparing output modes. The initial audible playback confirms that the system path can produce sound on the tested AirPods; release readiness requires the remaining physical results above.
