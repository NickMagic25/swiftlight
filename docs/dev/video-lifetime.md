# Video boundaries and ownership

`SwiftlightVideo` uses the local `MoonlightAppleVideo` C module from `Packages/moonlight-apple-decoder/` for HEVC/AV1 and the pinned `Dependencies/pyrowave` Metal library through `CPyrowaveBridge` for PyroWave. The codec selects its native backend internally; there is no decoder plugin selector or software fallback. Swift has no C++ interop. Canonical NV12 and P010 remain the HEVC/AV1 4:2:0 baseline. Explicit 4:4:4 selections use canonical bi-planar `444v`/`444f` or `x444`/`xf44`, with full-resolution UV planes and the same retained CoreVideo texture ownership. Experimental native packed formats and process environment controls are not enabled.

4:4:4 negotiation requires a profile-specific hardware probe on a worker before host launch. The probe decodes one representative access unit, confirms hardware output and the exact canonical format, and checks full-resolution chroma. Codec-wide hardware capability alone is insufficient. Each new connection can retry a temporarily unavailable profile; no failed probe is permanently cached. The ordinary decoder still enforces the selected chroma/depth, hardware-only output and low-delay HEVC restrictions. A 4:2:0 output cannot satisfy a 4:4:4 selection.

`VideoDecoder` owns the decoder handle and one private serial worker. Submit, capacity waits, drain, reset, and destruction enter that worker synchronously. The transport's one pull worker submits a complete copied access unit and releases the common-c frame according to submission success. Rejected/would-block inputs produce no terminal completion. Production capacity waits must be bounded, with transport shutdown able to stop new submissions before joining workers. A configuration-change would-block may require draining accepted old work before retrying the same unconsumed AU.

The C context is an unretained pointer to `CompletionMailbox`, whose strong owner outlives synchronous decoder destruction. The C callback only copies metadata, strongly retains its borrowed CVPixelBuffer or PyroWave GPU lease into an immutable `DecodedFrame`, and updates a short locked mailbox. No decoder call, GPU call, CPU mapping, external closure, or control wait occurs inside the callback. Inline completions may precede submit return: no mailbox lock is held across the C call, and accepted accounting is updated after return. The callback never guesses which submission is next; it preserves the decoder's frame and generation identities, no-display terminals, internal samples, and show-existing events.

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

## Direct PyroWave ownership

`CPyrowaveBridge` adapts Vibepollo record or legacy length framing directly in
the contiguous `Data` already copied by transport. Its checks cover the outer
input size, fragment ranges, record lengths/alignment and lost-fragment
boundaries needed to pass bounded intact ranges to the pinned native decoder.
It does not independently scan coefficient payloads or implement PyroWave's
sequence, block or readiness rules. The fork owns codec parsing, acceptance and
decode readiness through its native API. The bridge sends intact ranges without
copying the entire access unit or constructing a normalized record buffer.
Coefficient concatenation inside PyroWave and upload to its bounded Metal
buffers remain CPU copies; this is not a zero-copy compressed path. The encoder
and benchmark shaders are excluded from app builds.

Admission is capped at two accepted command buffers on one ordered Metal queue.
The fork has four upload slots and can wait when reusing an occupied slot; the
bridge's smaller admission bound ensures a slot's previous consumer has finished
before reuse. Capacity waits happen only on the private video worker. Native
corrupt-bitstream rejection or an incomplete frame returns a recoverable
submission rejection without consuming the caller's context or creating a
terminal completion. The next independent frame starts with cleared native
state. These native checks are the pinned fork's implementation; the bridge adds
no separate codec-validation pass. Authenticated transport color/HDR metadata
remains authoritative.

The private R8/R16 Y, Cb and Cr outputs are decoded and sampled directly on their
own Metal device. A reference-counted pool lease survives reset and destruction.
The pool has at most admission capacity plus four output slots; renderer-held
leases apply backpressure instead of growing texture storage. The renderer retains
the lease through command completion. There are no decoded CPU planes, readback
or synchronous GPU waits in normal presentation. Reset advances generation,
resolves accepted old work and then reopens admission.

`CNativeVideoABI` only copies HEVC/AV1 completion metadata. The published MAV
ABI-1 package has no optional backend trace tail, so those stages remain
unavailable. It can also safely read the local ABI-2 development package for
comparison without routing PyroWave through its decoder. Native fork symbols are
prefixed to prevent collision with that development package's PyroWave symbols.
