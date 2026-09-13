# Stream diagnostic exports

Choose **Stream → Export Last Stream Diagnostics…** after a connection attempt
ends, or use the same action in the library's computer-options menu. The action
is disabled until there is a retained report. The native save panel writes JSON
atomically to the selected location. Canceling the panel keeps the report available.
The existing live stream-options action still exports a current snapshot.

One completed report is retained **in memory for this app run**. Starting another
connection leaves the previous report available until the new attempt ends. An
unsuccessful connection also replaces it, with unavailable media fields omitted.
Disconnect, transport failure, network loss and suspension all finalize a report.
Export before quitting: reports are not persisted automatically, and a crash or
forced termination cannot finalize a report. No report is uploaded automatically.

## Schema 3

- App/OS versions, export capture time, connection settings, requested/decoded
  format strings, thermal state, terminal phase and safe failure category/code.
- Timeline start/end dates, monotonic elapsed duration and at most 600 recent
  samples. Samples contain stream statistics and phase, at most once per second
  plus an unconditional terminal sample. `discardedSamples` identifies truncation.
- Final decoder and renderer counters and their existing bounded timing arrays.
- Network RTT/deviation, frame and compressed-byte counters, queue depths,
  audio queued/underrun/overrun counters, and the bound socket's interface name.

The snapshot is frozen before native owners are cleared. Pending decode, audio or
presentation callbacks may finish later and are not included. The timeline includes
connection setup in elapsed time and may have gaps when the main run loop is delayed
or asleep; it is not a per-frame trace. Timing summaries retain their existing recent
sample windows, rather than becoming whole-session averages. See [stream statistics](stream-statistics.md)
for definitions, clock calibration, and estimated host-to-display limitations.
Non-finite numeric values, if any, encode as `NaN`, `Infinity` or `-Infinity` strings
so even a rejected configuration can be exported as valid JSON.

The payload deliberately omits host/client addresses, saved host IDs, app names,
PINs, OTPs, certificates, private keys, input events, media and raw error user-info.
An interface name such as `utun8`, stream preferences, uptime and OS version remain
useful debugging context. Failure reporting uses a type/category and numeric code;
full arbitrary error messages are not copied into the export.

## Validation

Three deterministic timeline tests cover rate limiting and truncation, terminal
sampling and completion freezing, pre-frame failures, JSON round-trip and invalid
or backward clocks. The full integrated suite passes 72 tests with hardware tests
enabled on the development Mac. Native save-panel interaction and an actual final
stream report still require an unlocked Mac and live stream; they have not been
claimed as verified while the user is away.
