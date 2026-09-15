# Stream statistics

On Mac, press **Control–Option–Shift–S** to show or hide statistics. Choose the detail and position in **Settings → Stream Statistics**; those Mac preferences save immediately.

On iPhone and iPad, statistics start hidden by default. In **Settings → Stream Statistics**, choose **Show statistics by default**, **Detail**, and **Position**, then tap **Save** to apply them to subsequent streams. **Cancel** discards your edits. During a stream, tap with three fingers or press **Control–Option–Shift–S** to show or hide the panel. Touch and hold with three fingers, or press **Command–Escape**, to open **Stream Controls**, where you can change visibility and detail for that stream. These in-stream changes do not change the saved default or preferences.

With VoiceOver on iPhone or iPad, use the **Game stream** element's **Show Statistics** or **Hide Statistics** custom action. Its **Stream Controls** action opens the same controls. When the panel is visible, individual statistics expose both their label and value to VoiceOver.

**Simple** shows the compact current status. **Detailed** adds recent timing summaries and negotiated video information. The panel can be placed **Top Left**, **Top Center**, or **Top Right** and updates during the current stream.

The panel may show requested and received video, codec and color, host processing, decode time, round-trip time, jitter, lost frames, and first-packet-to-display timing. Values can be **Unavailable** when the required measurement is missing; unavailable does not mean zero.

These are client-side diagnostics, not a complete input-to-photon or network-delay measurement. FPS is measured from received frames, not repeated screen redraws. Host-to-display is an estimate that uses host-reported processing, client timing, and half of the recent round-trip time; it is not synchronized one-way latency or physical scanout time.

Physical iPhone and iPad validation remains pending, including matched timing measurements with the panel hidden and visible. Successful compilation or simulator interaction does not establish that the panel has no effect on device streaming latency. See the [mobile guide](mobile.md) for performance settings, gestures, and current limitations.

For exact field definitions, clock assumptions, and implementation measurements, see [development statistics notes](dev/stream-statistics-implementation.md).
