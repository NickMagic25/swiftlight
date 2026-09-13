# Manual macOS release validation

The user requested to perform the full first-run pairing flow. No host has been pre-paired or launched by this implementation task.

Start with `scripts/build-app.sh`, then normally launch `.build/Swiftlight.app`. Use a stable development/distribution signature when evaluating permission persistence across rebuilt applications. Ad hoc local builds use the macOS login Keychain explicitly; locked Keychain access can require normal user interaction.

1. Follow [host-manual-test.md](host-manual-test.md) for discovery, manual IPv4/IPv6/custom port, PIN and Apollo OTP, cancellation, wrong credentials, expired/used credential, certificate-change trust review, unpair/re-pair, host removal and permission errors. Verify a second launch retains pairing without retaining OTP secrets.
2. Select HEVC SDR1080p60 initially. Confirm audio, keyboard including both sides of each modifier, Caps Lock, relative mouse capture, Control–Option–Shift–Q release, native fullscreen and application disconnect versus explicit quit. Confirm no remote quit occurs on window close, application quit, sleep or failure.
3. Test absolute mouse with fit/fill/integer and letterboxes. Middle/back/forward buttons outside the video rectangle must not click the last host position. Change relative/absolute mode while captured and confirm the local cursor is restored.
4. Connect/hotplug/unplug controllers; verify analog sticks/triggers, buttons, permission-denied classes and negotiated haptics. Hold keys/buttons/sticks while disconnecting, losing focus, canceling, sleeping, removing a device or closing the window; host input must be released.
5. Change settings, reconnect, then immediately cancel while teardown is pending. No new session should start. Switching hosts after suspension must never resume the old application ID on the new host. Explicit quit must finish before another launch is permitted.
6. Test HEVC and AV1 SDR/HDR10 where supported at requested4K60 and supported high-refresh modes. Compare requested size/FPS/bitrate with decoded size and presentation viewport. If HEVC encoding produces B slices/reordering, record the explicit decoder compatibility failure and configure a supported low-delay encoder; no alternate video decoder should activate.
7. For Native and Native—Safe Area, test normal/native-fullscreen windows on a notched Mac, scaled mode, resize and external display movement. Check exact even requested pixels, no double-applied safe inset, clean aperture and input alignment. Reconnect applies a newly requested native geometry.
8. Validate physical HDR on a supporting display: black, reference white, highlights, saturated colors, HDR-to-SDR display movement, SDR on HDR, brightness and Low Power Mode. Offscreen/readback and SDR screenshots do not establish HDR display correctness.
9. Switch wired/Bluetooth/headphone/default audio devices during a stream; verify route rebuild, no stale buffer burst, underruns and A/V sync. Measure latency rather than treating a configured queue bound as end-to-end audio delay.
10. Exercise Ethernet/Wi-Fi/VPN/IPv6, packet loss/reordering, network path loss/recovery, host sleep and repeated starts/stops. Export redacted diagnostics from the stream overlay. Compare the actual socket interface with global network status.
11. Use VoiceOver and keyboard navigation through hosts/library/settings/pairing/stream overlay. Verify controls remain reachable at small window sizes and increased text/contrast settings.
12. Run the [benchmark procedure](benchmarking.md), including 30-minute4K60 thermal/memory/queue/performance observation and matched reference-client/Game Mode trials.

Record the host version, encoder, Mac/OS, display/mode, network, actual command/interaction and pass/fail evidence for each acceptance row. Change BLOCKED to PASS only after that check succeeds. The iOS/iPadOS/tvOS rows remain future platform work.
