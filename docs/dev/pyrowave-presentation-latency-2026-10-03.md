# PyroWave first-packet-to-presentation diagnosis — 2026-10-03

The retained Release stream identifies the largest interval outside PyroWave's
displayed decode time: 6.810 ms passes before native decoder admission, versus
1.514 ms after its completion callback. The renderer is already close to the
expected roughly 1–2 ms cost for this workload. This investigation addresses
latency; it does not investigate or change frame-loss behavior.

## Evidence

The running app's **Stream → Export Last Stream Diagnostics** action provided
the completed 13:52:17–13:52:35 EDT connection. Its requested and received format
was 3440×1440, PyroWave 10-bit 4:4:4, PQ/Rec.2020, with a requested 165 FPS and
1500 Mbps. Actual presentation policy was immediate, VSync off, three drawables,
linear RGBA16Float output and a 165 Hz display. The production Metal statistics
panel was visible. The media socket used a tunnel interface; wired hardware alone
does not identify the stream's transport path.

`scripts/analyze-stream-latency.py` joined 1,024 confirmed presented frames over
6.978 seconds. Every detailed native/GPU stage was available on the same frames,
and the stage sum matched the total, with no missing or substituted intervals.
These are bounded recent samples from one stream, not a whole-session average,
physical scanout measurement, or a new matched HEVC/PyroWave experiment.

| Same-frame interval | Mean | p95 |
| --- | ---: | ---: |
| First packet → complete-frame enqueue | 6.545 ms | 7.313 ms |
| Complete-frame enqueue → native admission | 0.265 ms | 0.456 ms |
| Native admission → decode completion callback | 4.773 ms | 5.772 ms |
| Decode callback → render start | 0.037 ms | 0.049 ms |
| Render CPU → commit | 0.034 ms | 0.051 ms |
| Render commit → GPU start | 0.151 ms | 0.224 ms |
| Render GPU execution | 0.978 ms | 1.081 ms |
| Render GPU end → confirmed presentation | 0.313 ms | 0.457 ms |
| **First packet → confirmed presentation** | **13.097 ms** | **14.457 ms** |

Means above use an identical frame population and are additive; p95 values are
separate percentiles and must not be added. The time outside decode totals
8.324 ms: 81.8% is before admission. Decoder outstanding and render GPU in-flight
high-water marks were each one, with zero decoder capacity waits or renderer
capacity skips. This run therefore does not show a queue of decoded frames
causing the extra interval.

Within the displayed decode interval, CPU validation/preparation was 1.798 ms,
decode GPU execution 2.370 ms and GPU-end-to-decoder-callback delivery 0.109 ms.
Those are separate optimization opportunities already included in Decode time.

The sanitized raw export and analyzer output are retained in ignored
`artifacts/pyrowave-latency-2026-10-03/`. Export SHA-256:
`104bab7324f81e522e55de630b28e12e24942cd7df49a1d54fd6c6f293cdece2`.
No source or stream-quality settings were changed to collect it.

## What the receive interval means

The first timestamp is the first packet of this frame; complete-frame enqueue
occurs after RTP/FEC assembly and depacketization. Only then does the pull worker
copy and submit the access unit to the native decoder. Thus the 6.545 ms interval
includes arrival of the rest of the frame and receiver assembly work. It does
not mean 6.545 ms of rendering or GPU scheduling. Existing instrumentation does
not divide that interval into sender pacing, packet arrival span and receiver
CPU work, so attributing the entire interval to one of them would be premature.

Mean acquired compressed payload was 1,131,998 bytes per frame (about 1.13 MB).
That quantity alone would take 6.037 ms at an illustrative 1.5 Gb/s payload send
rate, before overhead. The requested codec bitrate is not a measurement of
the sender's active packet-pacing rate; the arithmetic only shows why frame
delivery can consume milliseconds even with successful packet delivery.

[Vibepollo's sender](https://github.com/Nonary/Vibepollo/blob/master/src/stream.cpp#L1854-L2040)
has a configurable packet pacer and sleeps between packet groups inside each
frame. Its active setting and installed implementation were not retrieved from
the host. The [codec protocol's rate control](https://github.com/Nonary/Vibepollo/blob/master/docs/pyrowave-protocol.md#rate-control)
also assigns the image a byte budget derived from configured bitrate and frame
rate. These mechanisms make sender pacing and frame size sensible next variables
to measure; they do not prove either setting caused the entire measured interval.

## Optimization priorities

1. **Shorten first-packet → complete-frame availability.** Measure actual
   first/last packet arrival span, receiver assembly CPU time and host pacer
   deadlines. Compare the same encoded workload with a verified faster packet
   send rate supported by the actual route. Smaller encoded frames are another
   option, with an explicit image-quality tradeoff. Re-measure presentation
   cadence and the same-frame path rather than assuming a requested bitrate
   changed arrival timing.
2. **Overlap validated PyroWave record processing with reception.** The current
   complete-access-unit boundary serializes reception and all decoder work.
   A bounded video-worker design could stage record validation and coefficient
   upload while later records arrive. CPU preparation alone currently takes
   1.798 ms. Such a design needs a new streaming-input/ownership contract across
   transport, bridge and fork: no decoder control on packet callbacks, no
   unfinished successful output, bounded storage, exact terminal completion,
   immutable GPU leases and generation-safe cancellation. This is a proposed
   architectural experiment, not an implemented or measured improvement.
3. **Keep smaller costs proportional to their measured budget.** Eliminating a
   transport copy could only recover part of the observed 0.265 ms enqueue-to-
   admission interval. Changing the main-thread handoff targets just 0.037 ms
   after decode. Fused reconstruction/rendering may reduce some GPU work, but
   it does not address the dominant 6.545 ms before a complete frame exists.

The photos' subtraction of rolling Decode time from rolling packet-to-display
means was a useful symptom. It cannot by itself isolate post-decode overhead:
those windows can contain different frames, and HEVC's displayed decode begins
at VideoToolbox submission while PyroWave's begins at native admission. The
joined export supplies the stage attribution above without that subtraction.
