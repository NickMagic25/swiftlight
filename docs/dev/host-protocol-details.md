# Host control and pairing

The macOS app uses the shared `SwiftlightHost` actor API. All host HTTP operations are async and cancellable. Bonjour advertises `_nvstream._tcp`; discovery resolves the service hostname and its HTTP port. Manual input accepts hostnames, IPv4, bare IPv6 with the default port, and bracketed IPv6 with a custom port. Discovered names are hints, not authenticated host identities.

## Protocol references

The implementation was checked against these immutable public upstream revisions on 2026-09-12:

- [Artemis PairingManager.java, c5cf27f4dc822db0e863c4691e7a70c74bea977a](https://github.com/ClassicOldSong/moonlight-android/blob/c5cf27f4dc822db0e863c4691e7a70c74bea977a/app/src/main/java/com/limelight/nvstream/http/PairingManager.java), SHA-256 `643a4a2893ae373d79d7fb829c9d6d17cdcc4d5e177f5645f97069766ffdd9b1`.
- [Apollo nvhttp.cpp, adc5c5a0bd80831ce495434bb16aee2cd4175fb8](https://github.com/ClassicOldSong/Apollo/blob/adc5c5a0bd80831ce495434bb16aee2cd4175fb8/src/nvhttp.cpp), SHA-256 `d23f2648ef1b0684792e32d8f4e08ce7206ffbdaae9144dcea9c184bcf195038`.
- [Apollo pairing link UI at the same revision](https://github.com/ClassicOldSong/Apollo/blob/adc5c5a0bd80831ce495434bb16aee2cd4175fb8/src_assets/common/assets/web/pin.html).
- [Apollo permission enum at the same revision](https://github.com/ClassicOldSong/Apollo/blob/adc5c5a0bd80831ce495434bb16aee2cd4175fb8/src/crypto.h).
- [Moonlight Qt certificate pairing, 63c48be6d425a62097cce97c64d001feb07e89e8](https://github.com/moonlight-stream/moonlight-qt/blob/63c48be6d425a62097cce97c64d001feb07e89e8/app/backend/nvpairingmanager.cpp).
- [Moonlight Qt HTTP control and launch, cdacb3d28dc9772bbf85e179cf51f8b25936df37](https://github.com/moonlight-stream/moonlight-qt/blob/cdacb3d28dc9772bbf85e179cf51f8b25936df37/app/backend/nvhttp.cpp).
- [Moonlight iOS certificate pairing, bbc89011d4a5613d3d3327cf1939fadf00598603](https://github.com/moonlight-stream/moonlight-ios/blob/bbc89011d4a5613d3d3327cf1939fadf00598603/Limelight/Network/PairManager.m).
- [moonlight-common-c public streaming API, 62e066388f1a1b133e0bee947b9a374311a3354b](https://github.com/moonlight-stream/moonlight-common-c/blob/62e066388f1a1b133e0bee947b9a374311a3354b/src/Limelight.h). This header is unchanged from the local Qt reference's `874ac954`.

The client's compatibility target is Sunshine/Apollo generation 7+ (SHA-256 pairing). Legacy SHA-1 NVIDIA generation 6 pairing is explicitly unsupported.

## Client pairing and upstream streaming boundary

Moonlight Qt and Moonlight iOS implement discovery, HTTP host control and the certificate/PIN exchange in their client layers. The pinned common-c public API starts a stream using `SERVER_INFORMATION`, `STREAM_CONFIGURATION` and callbacks; it does not expose a discovery, certificate/PIN or Apollo OTP pairing API. Swiftlight follows this upstream boundary: `SwiftlightHost` implements the existing client HTTP protocol using URLSession and Security, while the transport uses upstream common-c for the streaming connection and input protocol. The Apollo OTP extension follows the Artemis/Apollo sources above and still completes the standard certificate exchange.

After authenticated `/serverinfo` and `/launch` or `/resume`, Swiftlight passes the server version, codec capabilities, returned `sessionUrl0`, and the same ephemeral input AES key and key ID to the common-c configuration used by `LiStartConnection`. `LiGetLaunchUrlQueryParameters` supplies common-c's extensions to the client's HTTP launch/resume query, as it does in Moonlight Qt. Common-c then owns RTSP negotiation and the video, audio, control and input transport; compressed video delivery reaches the exclusive MoonlightAppleVideo decoder. Local disconnect calls `LiStopConnection`; the client sends HTTP `/cancel` only for the separate explicit quit action.

The app permits the protocol's initial HTTP exchange with user-entered DNS names using `NSAllowsArbitraryLoads`, matching the Moonlight Qt/iOS app configuration. `NSAllowsLocalNetworking` alone excludes names such as a tailnet's fully qualified DNS hostname; live macOS testing reproduced ATS error `-1022` before the request reached the host. Do not combine the two keys: [Apple documents that the more specific key overrides the general exception](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CocoaKeys.html). This app transport exception does not bypass Swiftlight's exact certificate pin, signed pairing proof, or client-certificate authentication. Arbitrary host HTTPS requests still require the pinned certificate in `HostSessionDelegate`; redirects remain rejected.

## PIN and identity

One stable random client identifier, RSA-2048 private key, self-signed client certificate, and PKCS#12 import envelope are persisted as a non-synchronizing Keychain item. The private key is never written to the host metadata JSON, logs, or UserDefaults. The PKCS#12 password is random and also remains inside the Keychain envelope. On macOS 15+, identity import uses `kSecImportToMemoryOnly`; older macOS uses Security's normal Keychain import behavior. RSA signing and certificate encoding use the pinned OpenSSL dependency already required by common-c; TLS, networking, storage and random generation use Apple frameworks.

Keychain routing is an explicit platform choice made before any operation. The current macOS app uses the login Keychain via `SecItem` (`kSecUseDataProtectionKeychain = false`), whose lock state and application access controls protect the item. This works with the current unprovisioned development bundle. iOS/tvOS use the required data-protection Keychain with `AfterFirstUnlockThisDeviceOnly`. A correctly provisioned macOS distribution may explicitly choose `HostKeychainBackend.dataProtection`; the application must then carry the authorized Keychain access-group entitlement and provisioning profile described in [Apple TN3137](https://developer.apple.com/documentation/Technotes/tn3137-on-mac-keychains). The implementation never silently switches backends after an error. Switching backend without a deliberate identity migration requires re-pairing.

Relaunching the same signed app should recover the same login-Keychain identity. Rebuilding an ad-hoc signed app can change its code identity and cause an OS Keychain authorization prompt; a stable Developer ID signing identity avoids treating each development build as a new trusted executable. User cancellation or locked-Keychain failures surface as a Keychain error rather than creating an identity elsewhere. Persistent Keychain behavior remains a manual app acceptance check; unit tests inspect query dictionaries without accessing a real Keychain.

The shared identity store keeps the client identity and up to 256 pin hit/miss results in process memory. This avoids repeating `SecItemCopyMatching` for every server-info, library and launch request. Pairing writes and explicit Unpair/Forget update the cache only after the corresponding Keychain operation succeeds; failures are never cached as missing items or successful changes. A fresh store/process reads Keychain again. External edits made in Keychain Access while the app is running are observed after reopening the app; the app's own trust-removal actions take effect immediately. Cache eviction also causes a fresh read. No cache data is written outside Keychain.

A consumer release needs a stable bundle identifier and distribution signing identity/designated requirement across updates. Apple's [code-signing guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/AboutCS/AboutCS.html) explains that Keychain tracks an application's designated requirement; [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) covers identity changes between development and distribution channels. An ad-hoc development rebuild is not representative of that release experience. Moving an existing development-created item to the distribution app may still require an initial authorization. Caching does not override an item's access controls or prevent a prompt when the Keychain is locked or the app's identity no longer matches. Release acceptance must include ordinary relaunch and a signed app update with the same designated requirement on an unlocked login Keychain.

The standard pairing sequence is:

1. Fetch unpaired `/serverinfo` and the advertised HTTPS port.
2. Generate 16 salt bytes; derive the first 16 bytes of `SHA256(rawSalt || UTF8(PIN))` as an AES-128 key. Send the client certificate and uppercase hexadecimal salt to HTTP `/pair?phrase=getservercert`. This waits at most 120 seconds for manual PIN entry.
3. Exchange the AES-ECB client challenge and server challenge hash. Verify the server's RSA/SHA-256 signature and PIN-derived challenge hash before trusting its certificate.
4. Send the signed client secret, then complete HTTPS `pairchallenge` against the exact bootstrapped leaf-certificate pin using the client identity.
5. Read authenticated server info, validate the host ID and paired state, then persist the server certificate in Keychain. No pin is committed on failure.

Each ordinary stage has a timeout; cancellation attempts bounded three-second `/unpair` cleanup in a separate task. A paired host never falls back to unauthenticated HTTP responses after a TLS failure. The HTTP discovery of a custom HTTPS port is followed by pinned authenticated revalidation. An unauthenticated HTTP `PairStatus=1` does not establish local trust: public host info remains unpaired until a certificate pin exists and TLS authenticates the response. The raw field remains available for protocol diagnostics. This keeps pairing available after local trust is missing or removed. Certificate replacement is an explicit user recovery flow; it is never silently accepted. Requests reject all redirects and disable cookies and caches. Response streaming rejects a declared length above 4 MiB before body processing and bounds accumulated data when the length is absent. The implementation does not log request URLs, credentials, response bodies or signatures.

When a new address reports a previously paired host ID, the first refresh retrieves that ID's candidate pin and verifies it over TLS before reporting paired status. A stored pin with authenticated `PairStatus=0` produces a pairing failure; it does not report successful pairing or automatically replace trust. The explicit recovery action removes the old pairing before a new PIN exchange.

The async byte request explicitly receives a task delegate that handles both server trust and client-certificate challenges, using the same policy as the session delegate. [Apple documents the delegate parameter as the receiver of authentication callbacks](https://developer.apple.com/documentation/foundation/urlsession/bytes(for:delegate:)). Omitting it failed a real loopback mutual-TLS experiment with URL error `-1202` before the session handler ran. With the delegate supplied, the same synthetic peer succeeds. A rejected certificate also causes URL error `-999`; its recorded pin rejection must be classified before generic cancellation. Other URL failures retain only their numeric error code, without URL or credential details.

Apollo records its client entry after HTTP `clientpairingsecret`, before HTTPS `pairchallenge`. A host WebUI entry therefore proves that the signed PIN exchange reached that stage, but does not prove that mutual TLS, authenticated server info, or local pin persistence succeeded.

## Apollo OTP link

Accepted syntax is `art://HOST:HTTPPORT?pin=OTP&passphrase=...&name=...`, including bracketed IPv6 and percent-encoded values. Duplicate fields, userinfo, unexpected fields, fragments, invalid ports and nonnumeric OTPs or OTPs of lengths other than four digits are rejected. Separate address, OTP and passphrase fields use the same credential type. A plus sign is treated literally, matching URL query semantics; `%2B` also decodes to plus.

Artemis computes:

```text
saltText = UPPERHEX(raw16Salt)
otpauth = UPPERHEX(SHA256(UTF8(OTP + saltText + passphrase)))
```

This value is sent in the normal `getservercert` query; the OTP still supplies the PIN for the certificate challenge. It is not a bearer token, a media authentication replacement, or a host administrator credential. The credential type is not Codable and its descriptions are redacted. It is released after pairing rather than persisted.

The Swift tests and `python3 docs/dev/host-otp-vectors.py` share two independently computed vectors, including an uppercase salt with A-F and Unicode/space/plus/ampersand in the passphrase. No real pairing material is in the fixtures.

The selected Apollo implementation intentionally returns a plausible positive certificate response for an invalid, expired or already-used OTP, then causes the cryptographic challenge to fail. It therefore does **not** provide enough information to distinguish those three failures. Swiftlight reports this accurately as a rejected credential and asks for a newly generated link. It separately classifies malformed local input and an explicit server 503 when available. A reusable arbitrary API token is not implemented because no verified non-administrator contract was supplied; the normal flow never asks for an Apollo admin cookie or password.

Apollo permission masks are exposed on authenticated `HostInfo`. Library and launch/resume operations enforce the corresponding action grants; the app can also gate individual input classes. Apollo's synthetic “Permission Denied” application is recognized as a permission error.

## Session operations

`launch` and `resume` send the requested dimensions/frame rate, shared ephemeral input AES key and key ID, audio/controller preferences, and HDR flags when requested. `additionalQuery` accepts common-c's launch extensions without allowing it to override identity, encryption, or core request values. The same key/ID must be passed to common-c. The returned RTSP/RTSPENC session URL is handed to the transport.

Disconnect stops only the local transport. Only `quitApplication` sends `/cancel`, and it confirms `currentgame == 0` afterward. `unpair` is an explicit host operation; `forgetPairing` removes local trust without contacting a host whose certificate may have changed. `SavedHostStore` only saves nonsecret host ID, display name and address.

## Evidence and boundaries

`swift build --target SwiftlightHost` compiles the host module under Swift 6. All 19 host tests passed on the development Mac, as did the independent Python OTP vectors. Run `swift test --filter SwiftlightHostTests`; `--skip-build` can execute the already-built test bundle while independent application files are being edited. The host tests use an in-process cryptographic peer and memory-only identity store: they do not discover, pair, launch or quit a real host. They cover complete PIN and OTP exchange, wrong PIN, tampered proof, cancellation cleanup, certificate changes, untrusted paired-status reports followed by successful PIN pairing, first-refresh host-alias trust lookup, rejection of stored-pin/unpaired-host success, URL/XML validation, metadata persistence, explicit platform Keychain query construction, and the distinction between disconnect and explicit quit. Four cache tests inject memory-only Keychain I/O and verify read reuse, fresh-store reads, pairing updates, failed operations, and explicit client Unpair/Forget invalidation. The PKCS#12 test uses memory-only Security import on macOS 15+.

On macOS 15+, a separate Network.framework fixture binds only to `127.0.0.1` on an ephemeral port and requires the generated client's exact certificate. It exercises real `URLSession.AsyncBytes` mutual TLS and changed-pin rejection. Both identities remain in memory; it needs no OpenSSL executable, external host, stored credentials, or GUI interaction.

The [2026-09-12 pairing follow-up](pairing-fix-validation.md) separately verified saved pairing across app relaunch, real mutual TLS, and authenticated application-library access against the user's Vibepollo host over Tailscale DNS. Discovery/permission variants, host-specific permission grants, pairing recovery and stream interoperability still require the remaining checks in [the manual test procedure](host-manual-test.md). No live-host result is claimed by the protocol fixtures.
