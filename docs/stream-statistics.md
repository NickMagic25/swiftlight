# Stream statistics

Enable statistics with **Control–Option–Shift–S**, or choose a style and position in **Settings → Stream Statistics**. **Simple** shows the compact current status. **Detailed** adds recent timing summaries and negotiated video information. The panel can be placed Top Left, Top Center, or Top Right and updates during the current stream.

The panel may show requested and received video, codec and color, host processing, decode time, round-trip time, jitter, lost frames, and first-packet-to-display timing. Values can be **Unavailable** when the required measurement is missing; unavailable does not mean zero.

These are client-side diagnostics, not a complete input-to-photon or network-delay measurement. FPS is measured from received frames, not repeated screen redraws. Host-to-display is an estimate that uses host-reported processing, client timing, and half of the recent round-trip time; it is not synchronized one-way latency or physical scanout time.

For exact field definitions, clock assumptions, and implementation measurements, see [development statistics notes](dev/stream-statistics-implementation.md).
