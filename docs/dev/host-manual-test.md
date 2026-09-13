# Manual host acceptance test

The user requested that the complete real pairing flow remain available for manual testing. No host is pre-paired and no test credential is installed by the build.

Record the macOS version, signed app build, host application/version, host HTTP port and network type with results. Do not attach PINs, pairing links, passphrases, private keys, full query URLs, or authentication logs.

1. Launch the packaged app normally. Allow Local Network permission when prompted. Confirm a reachable Sunshine/Apollo host appears through Bonjour. Confirm denial produces useful guidance and manual entry remains available.
2. Add the host using its IPv4/hostname and HTTP port. For a separate network test, repeat with IPv6 and a custom port. Open its pairing flow. Enter the displayed PIN into the host's PIN page and verify successful pairing opens the application library.
3. Relaunch Swiftlight. Confirm the same client identity stays paired without entering another PIN. Confirm the saved library is fetched through authenticated host control.
4. Cancel a pending pairing attempt before entering the PIN. Begin again. Let another attempt time out. Confirm both recover without a stuck spinner or silently saved pairing. Enter an incorrect PIN and confirm a recoverable PIN error.
5. If using Apollo, generate a fresh OTP link in its management UI. Paste the complete `art://` link; separately test its host/port, OTP and passphrase fields. Include a custom port and a host name containing spaces. Confirm the resulting normal certificate pairing survives app relaunch. Try malformed input, an incorrect passphrase, an expired link and a previously used link. The last three may share Apollo's deliberately opaque rejection response.
6. Change only this client's Apollo permission grants. Confirm library/view/launch restrictions produce permission guidance. Verify keyboard, mouse and controller restrictions individually. Do not infer a network or decoder failure from a permission denial.
7. Launch an app, disconnect locally with **Control–Option–Shift–Q** or **Disconnect**, and confirm the app continues running on the host. **Control–Option–Shift–Z** only releases input capture; **Control–Option–Shift–S** toggles statistics without changing the connection. Resume the app after disconnecting. Use **Quit Remote Application**, confirm the destructive intent in the UI, and check it terminates on the host.
8. Remove the pairing and re-pair. In a disposable host configuration, replace its server certificate. Confirm Swiftlight refuses authenticated operations until the host identity is verified and local trust is explicitly removed. It must never automatically accept the replacement.
9. For stream verification, record the negotiated codec/HDR state, native/safe content geometry, requested/actual resolution, audio, input, reconnect behavior and visible frame progression using the broader acceptance matrix. A successful library or launch response alone does not prove a healthy media stream.

Keep real device/host results separate from fixture tests. If a step fails, record the displayed error and operation stage without secrets, plus host service logs with authentication material redacted.
