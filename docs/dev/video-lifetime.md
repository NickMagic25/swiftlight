# Video boundaries and ownership

`SwiftlightVideo` depends on the pinned `MoonlightAppleVideo` C Clang module. It has no Swift C++ interop, alternate video decoder, decoder plugin selector, or software fallback. Canonical NV12 and P010 are the baseline. Experimental `&8v0`/`&xv0` formats and process environment controls are not enabled.

`VideoDecoder` owns the decoder handle and one private serial worker. Submit, capacity waits, drain, reset, and destruction enter that worker synchronously. The transport's one pull worker submits a complete copied access unit and releases the common-c frame according to submission success. Rejected/would-block inputs produce no terminal completion. Production capacity waits must be bounded, with transport shutdown able to stop new submissions before joining workers. A configuration-change would-block may require draining accepted old work before retrying the same unconsumed AU.

The C context is an unretained pointer to `CompletionMailbox`, whose strong owner outlives synchronous decoder destruction. The C callback only copies metadata, strongly retains its borrowed CVPixelBuffer into an immutable `DecodedFrame`, and updates a short locked mailbox. No decoder call, GPU call, CPU mapping, external closure, or control wait occurs inside the callback. Inline completions may precede submit return: no mailbox lock is held across the C call, and accepted accounting is updated after return. The callback never guesses which submission is next; it preserves the decoder's frame and generation identities, no-display terminals, internal samples, and show-existing events.

The mailbox holds exactly one latest frame. Replacing it releases the old owner and increments a presentation-skip counter. Reset suppresses output, clears that mailbox, invokes reset, and reopens presentation only after the C contract guarantees old callbacks have ended. Accepted work always retains terminal accounting. Drain preserves reference state. Close is idempotent and synchronous; already retained frames remain valid after close.

Finite visible replay retains its drained decoder and last mailbox/view frame in Completed until Stop or window close, allowing the final frame to reach a later display tick. Completed is not decoder destruction and need not have zero live frame owners. Replacement playback waits for the old decoder worker to finish destruction; GPU leases still release asynchronously at command completion.

Boundaries and maximum owners:

| Boundary | Bound | Overflow |
| --- | --- | --- |
| Transport complete compressed AU | One pull-worker frame, maximum 32 MiB | Reject malformed/oversized units; no backlog in Swift |
| Decoder outstanding accepted AUs | Two by default | Would-block consumes nothing; worker waits/retries or requests IDR |
| Decoded presentation mailbox | One retained frame | Latest wins; count replaced frames |
| GPU submissions | Three maximum | Skip render admission; never wait in display callback |
| Terminal identity diagnostics | Last 256 IDs | Overwrite oldest |
| Timing/presentation diagnostics | Last 1,024 samples per series | Overwrite oldest |

The Metal renderer creates plane views from retained buffers. A `TextureLease` owns the buffer and both `CVMetalTexture` wrappers until command completion. The wrappers are essential even while derived `MTLTexture` objects exist. Encoding/cache/pipeline access uses a separate lock from short counter updates. Core Animation and Metal calls never run under the metrics lock acquired by callbacks. Drawable handler registration, presentation and command commit also run outside the encoding lock; commands are enqueued before that lock is released to preserve concurrent ordering. This avoids the observed lock inversion between a registering render and Core Animation's presented callback. A lease is populated before command commit, and its single completion clears references after GPU execution. No caller reads those fields after commit. Normal presentation never maps CPU planes or waits for GPU completion. Completion metrics are bounded and record actual `presentedTime` separately from GPU execution.

`@unchecked Sendable` is limited to these documented synchronized or immutable owners. `DecodedFrame` exposes an immutable decoded buffer for read-only CoreVideo/Metal consumers; callers must not lock it for writes. Its process-wide locked diagnostics count acquired/released/live/high-water owners. Replay requires live owners to return to zero after decoder destruction and GPU completion.

Clock values named `arrivalNanoseconds` and `firstPacketNanoseconds` must already be in `mav_monotonic_time_ns`'s domain. PTS is media time and never used as an arrival timestamp. Replay's synthetic pacing uses this clock directly. Core Animation's actual presentation times remain separate until a measured clock calibration is applied; they are not subtracted from transport or RTP clocks.

`contentRect` converts CoreVideo's lower-left clean-aperture coordinates to top-left source pixels and clips them to valid output. The renderer honors clean aperture, plane extents, aspect-fit letterboxes and aspect-fill cropping. Input should use the identical visible rect and scale policy. No claim is made that square-pixel synthetic fixtures validate anamorphic/sample-aspect-ratio content.
