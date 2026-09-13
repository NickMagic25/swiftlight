# Stream statistics

## Reading the panel

Press **Control–Option–Shift–S** to show or hide statistics without releasing input capture. In **Settings → Stream Statistics**, choose **Simple** or **Detailed**, and **Top Left**, **Top Center** or **Top Right**. Defaults are **Simple / Top Center**. These preferences save immediately, apply to every computer and persist across launches; changing them does not require reconnecting.

In **Simple**, **First packet → display** shows the latency of the most recently presented distinct frame at each five-second refresh and holds that value between refreshes. This is a current-frame sample, not a rolling average. The latest frame is selected by its actual presentation time. Missing timing on that frame or no fresh presentation within five seconds makes the reading unavailable. Other Simple timing rows retain their recent averages and normal update cadence.

**Detailed** keeps rolling timing summaries in **minimum / maximum / average** order, including **First packet → display**, at the normal 4 Hz update cadence. It also adds negotiated codec, decoded color and the host-to-display estimate. Times use milliseconds. “Unavailable” means a required measurement is absent or invalid, rather than a measured zero. Native measurements and exported diagnostics continue updating independently of the held Simple value.

- **Requested video / format** describe the connection request. **Received video** combines dimensions from decoded output with complete received frames per second measured over a recent window. Received FPS does not count repeated display refreshes. **Negotiated codec** describes the selected codec and bit depth; **Decoded color** describes decoder output, with assumed metadata identified explicitly.
- **Host processing** is the host-reported processing duration. **Decode time** measures the client's VideoToolbox submission to callback interval. Neither includes the complete streaming journey.
- **Network latency (RTT)** measures the control channel's round trip. **Network jitter** measures variation between frame arrivals relative to their RTP timestamps; host pacing and client scheduling also contribute. It does not isolate network delay. **Frames lost to network** counts irrecoverable RTP frames across the connection, separately from local decoder or presentation drops.
- **First packet → display** measures a frame's first received packet to its confirmed drawable presentation. **Host → display (estimated)** adds that interval to the same frame's host processing duration, then adds half the recent average RTT. Half RTT assumes symmetric transit, and the RTT samples use a separate window. This is an estimate without synchronized host clocks, physical scanout measurement or input-to-photon timing.

## Transport measurements

`StreamTransport.diagnostics.video` reports connection-lifetime frame counters and bounded recent timing summaries. The RTP receive thread performs only relaxed atomic counter increments; the existing pull worker records decode-unit metadata with constant-time updates to two fixed 1024-sample timing rings. A low-rate snapshot computes their min/max/mean under a short dedicated mutex. No decoder, Swift callback, network operation, or lifecycle call runs while that mutex is held. The existing API gate excludes concurrent start/stop when sampling the common-c counters. A new transport/queue starts all counters and windows empty.

| Value | Source and exact meaning |
|---|---|
| `receivedFrames` | Full RTP frame reassembly, including successful Reed-Solomon recovery, before depacketizer IDR/recovery filtering or local decode-queue overflow. |
| `networkLostFrames` | Frames the RTP queue has irreversibly skipped because packets, earlier FEC blocks, or whole frame indices were missing. Speculative loss notifications do not increment it; later confirmation increments it once even when the earlier notification suppresses another RFI request. |
| `totalFrames` | `receivedFrames + networkLostFrames`. Pending incomplete frames do not enter either outcome counter until completed or declared unrecoverable. |
| `acquiredFrames`, `acquiredBytes` | Decode units acquired by the bridge pull worker and their bounded declared compressed payload lengths. These exclude transport/FEC overhead and frames filtered by the depacketizer. They are not wire throughput or displayed-frame counts. |
| `firstReceiveUptimeNanoseconds`, `lastReceiveUptimeNanoseconds` | First-packet timestamps carried by acquired decode units, converted to `CLOCK_UPTIME_RAW`. Missing timestamps remain `nil`. The last value may lag RTP reception while decoder admission is blocked. |
| `hostProcessingLatency` | Host-supplied `DECODE_UNIT.frameHostProcessingLatency`, in tenths of a millisecond. Multiply the raw value by 0.1 for milliseconds. A raw zero means absent metadata or a repeated frame and is excluded. |
| `reassemblyTime` | `enqueueTimeUs - receiveTimeUs` for acquired decode units with valid ordered timestamps: first packet to complete access-unit assembly/queueing. It excludes the subsequent wait for decoder admission. |
| `frameArrivalJitterMilliseconds` | EWMA of the absolute difference between consecutive complete-frame first-packet arrival intervals and the corresponding 90 kHz RTP timestamp intervals. Smoothing is `J += (abs(arrivalDelta - rtpDelta) - J) / 16`, starting at zero. No valid interval means `nil`. |
| `rttMilliseconds`, `rttVarianceMilliseconds` | Existing common-c/ENet control-channel smoothed RTT and smoothed absolute RTT deviation, both in milliseconds. The historical variance name does not indicate squared variance or video-packet jitter. |

Each `TimingSummary` contains `sampleCount`, `minimumMilliseconds`, `maximumMilliseconds`, and `averageMilliseconds` for the most recent 1024 valid samples of that kind. Missing measurements do not become zero-valued samples. The same optional host duration accompanies each `CompressedVideoFrame` so presentation metrics can correlate metadata with that exact frame.

Use counter deltas divided by an actual monotonic polling interval for receiving/source FPS. Requested FPS is a configuration target. Never call decode-unit receipt or repeated rendering of a retained drawable “displayed FPS.” The two RTP outcome atomics are sampled individually during a diagnostics call; they do not promise the exact same receive instant.

The frame-arrival estimator uses the smoothing equation from [RFC 3550 §6.4.1 and Appendix A.8](https://www.rfc-editor.org/rfc/rfc3550#section-6.4.1), applied to one first-packet timestamp per acquired frame. It is **frame arrival variation**, not the RFC's all-packet RTCP statistic or isolated network delay. Host capture/encode pacing and receive scheduling also contribute. Zero/repeated or backward RTP intervals and invalid receive intervals are excluded; normal 32-bit RTP wrap is supported. Hosts with no progressing RTP timestamp leave it unavailable. There is no synchronized host/client clock measurement of one-way network time, input-to-photon delay, or physical panel response.

Network loss means missing data at the client's RTP reconstruction boundary; it does not locate the loss on a link, server, or local socket buffer. Common-c assumes host frame indices progress contiguously. A never-observed trailing frame cannot be counted, and a final partially received frame stays pending unless a subsequent packet establishes that it cannot be recovered. Local downstream decoder/presentation drops are separate counters. No network loss or latency has been measured against a live host as part of these transport tests.

## Upstream comparison and patch scope

The inspected local reference revisions were Moonlight Qt `d127908564e53e7888fa691f5e0004a1d75cef75`, Moonlight iOS `85af0f75622bb2636481afda8b0fc5cc33d5956e`, and VoidLink `5d3985e7d2c75293082885a2e83006efebb1a213`.

- [Qt `ffmpeg.cpp`](https://github.com/moonlight-stream/moonlight-qt/blob/d127908564e53e7888fa691f5e0004a1d75cef75/app/streaming/video/ffmpeg.cpp#L2100), [iOS `Connection.m`](https://github.com/moonlight-stream/moonlight-ios/blob/85af0f75622bb2636481afda8b0fc5cc33d5956e/Limelight/Stream/Connection.m#L112), and [VoidLink `Connection.m`](https://github.com/The-Fried-Fish/VoidLink-previously-moonlight-zwm/blob/5d3985e7d2c75293082885a2e83006efebb1a213/VoidLink/Stream/Connection.m#L163) infer “network dropped” frames from gaps in delivered decode-unit frame numbers and aggregate the same optional host-processing field. That gap count can include recovery filtering or local queue overflow in common-c, so Swiftlight does not use it as an exact network-loss count.
- [Common-c `VideoDepacketizer.c`](https://github.com/moonlight-stream/moonlight-common-c/blob/62e066388f1a1b133e0bee947b9a374311a3354b/src/VideoDepacketizer.c#L470) defines the decode-unit handoff. Queue overflow can discard already received frames; IDR/recovery filtering can also withhold a complete frame. `connectionDetectedFrameLoss` and `notifyFrameLost` ranges serve recovery, so counting every notification would misclassify received/recoverable frames.
- [Common-c `RtpVideoQueue.c`](https://github.com/moonlight-stream/moonlight-common-c/blob/62e066388f1a1b133e0bee947b9a374311a3354b/src/RtpVideoQueue.c#L596) has three irreversible skip paths and a final-FEC success path. Targeted patch `0004-count-confirmed-rtp-frame-outcomes.patch` adds atomic counters exactly there and a read-only accessor. It does not change any recovery, packet ownership, network callback, or codec decision.
- Common-c `Limelight.h` documents host-processing ticks and receive/enqueue timestamp meanings. `ControlStream.c:LiGetEstimatedRttInfo` reads existing ENet estimates without taking its mutex; these remain approximate upstream snapshots. ENet `protocol.c:enet_protocol_handle_acknowledge` smooths RTT by 1/8 and absolute deviation by 1/4. Neither value is a video jitter measurement.

## Offline transport validation

```sh
python3 scripts/prepare-common-c.py
swift test --filter TransportTests
scripts/validate-transport-native.sh
SWIFTLIGHT_SANITIZERS=thread scripts/validate-transport-native.sh
```

The native suite passed ASan/UBSan and TSan after this change. The actual patched RTP queue is linked into a separate executable with no-host callbacks; eight packet-path scenarios cover whole-frame loss, duplicates, incomplete/missing FEC blocks, speculative notification followed by out-of-order recovery, speculative notification followed by confirmed loss, real Reed-Solomon reconstruction, and frame-number wrap. A reader races 100,000 actual frame-reassembly updates and verifies monotonic counter snapshots. Queue reinitialization resets both counters. A downstream callback discards packet storage, ensuring receive accounting remains independent of decoder output.

The bridge suite verifies host units, absent metadata, valid zero timing, timestamp order, RTP wrap, exact ring eviction/min/max/sum, and 100,000 metadata writes racing snapshots. The native tests use always-on `CHECK` expressions even though ordinary upstream debug assertions are disabled. They use no sockets, audio devices, real host, or GUI.

Logs: `artifacts/transport-telemetry-asan.log`, `artifacts/transport-telemetry-tsan.log`, and `artifacts/transport-telemetry-swift-tests.log`. The focused Swift run initially passed eight transport tests; a ninth Swift value-conversion test was then added for the full application test run. These sanitizer results validate the exercised paths, not every common-c network operation or live performance.

## Decoder and presentation timing

The overlay polls bounded snapshots at the existing 4 Hz UI cadence. Native frame callbacks update counters and scalar metadata without publishing SwiftUI state or waiting for the GPU. Decode time is the decoder's VideoToolbox submit-to-callback interval, summarized as min/max/mean over its most recent 1024 valid single-sample intervals. AV1 show-existing events and multi-sample aggregate completions are excluded. This interval ends before renderer import, GPU conversion, or presentation.

“First packet → display” begins at the exact frame's first received packet and ends at its first confirmed `MTLDrawable.presentedTime`. It includes access-unit reassembly, admission/decoder work, and client presentation scheduling. A positive, finite drawable timestamp is required; a zero timestamp remains unconfirmed. Repeated redraws do not create new timing samples, and an earlier presentation notification delivered out of order replaces the same frame's sample. The renderer retains at most 1024 distinct confirmed frames; summaries exclude entries with unavailable timing.

The packet/decoder clock is `CLOCK_UPTIME_RAW`, while drawable timestamps use the Core Animation clock. Each presentation callback takes three calibration samples, each bracketing `CACurrentMediaTime()` with `mav_monotonic_time_ns()` reads, and uses the narrowest bracket to map the two epochs. Half the bracket is recorded as sampling uncertainty. Missing, nonfinite, negative, or more-than-1-ms-uncertain intervals are excluded rather than replaced with zero. The mapping assumes locally stable unit-rate clocks; its uncertainty describes clock sampling, not panel response. All clock and drawable-property reads occur before the renderer metrics lock, preserving the callback lock-order fix. Presented callbacks retain only scalar timing metadata; pixel-buffer and CoreVideo texture ownership still ends after GPU completion.

## Estimated host-to-display time and observed format

The detailed overlay computes:

```text
Host → display (estimated)
  = mean(host processing + first packet → drawable presentation, paired per frame)
    + mean(control-channel RTT) / 2
```

The paired mean includes only frames with both a valid host duration and measured client interval. The RTT mean comes from independent recent polls (up to five seconds, bounded at 64 samples); these are different sample windows. Half RTT assumes symmetric transit and is not measured one-way video delay. There is no synchronized host-processing-start timestamp, physical scanout measurement, or input-to-photon measurement. Missing paired timing or RTT makes the estimate unavailable. The standalone host-processing row includes recent acquired frames and can therefore differ from the host durations of frames actually presented.

Received FPS uses deltas of the RTP complete-frame counter divided by actual monotonic elapsed time, over an approximately five-second window. It is neither requested FPS nor repeated-drawable refresh rate. Common-c's setup width, height, and FPS echo requested configuration values; they do not establish the host's observed output size or rate. The overlay takes negotiated codec/bit depth from setup, received dimensions and decoded color from decoder output, and measured FPS from RTP counter deltas. Color description or range defaults are explicitly marked “assumed” when their decoder validity bits are absent.
