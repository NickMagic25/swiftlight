# Host application artwork

`HostClient.artwork(appID: Int) async throws -> Data` returns the original encoded cover from that client's bound host address. The application owns thumbnail sizing and a bounded cache. A missing or rejected image should leave the app tile's placeholder available rather than fail library loading.

## Protocol and trust

The request is a GET to the host's HTTPS `/appasset` endpoint with `appid`, `AssetType=2`, `AssetIdx=0` and the existing client `uniqueid` and per-request `uuid`. This follows [Moonlight Qt's `NvHTTP::getBoxArt`](https://github.com/moonlight-stream/moonlight-qt/blob/d127908564e53e7888fa691f5e0004a1d75cef75/app/backend/nvhttp.cpp#L392), [Moonlight iOS's `newAppAssetRequestWithAppId`](https://github.com/moonlight-stream/moonlight-ios/blob/85af0f75622bb2636481afda8b0fc5cc33d5956e/Limelight/Network/HttpManager.m#L298), and [VoidLink's matching request](https://github.com/The-Fried-Fish/VoidLink-previously-moonlight-zwm/blob/5d3985e7d2c75293082885a2e83006efebb1a213/VoidLink/Network/HttpManager.m#L312), inspected at those pinned local revisions. Common-c does not fetch library artwork.

A saved certificate pin is required before any artwork request. If this `HostClient` has not loaded server information, it first uses the existing server-info flow to discover a custom HTTPS port and authenticate the host. Subsequent covers reuse that information. Only this metadata bootstrap can use HTTP; `/appasset` always uses exact leaf-certificate pinning and the existing client TLS identity. A failed certificate, permission denial, timeout or missing asset never triggers an HTTP retry. Redirects remain disabled. Pairing, credential storage and remote application state are unchanged.

## Resource bounds

The existing ephemeral URLSession transport enforces a 10-second request/resource timeout and a 4 MiB body limit, checking advertised length before collecting bytes and enforcing the same limit while streaming an unknown-length response. HTTP 401/403 produces `permissionDenied`; other non-200 statuses retain their typed host-status error.

Before returning data, ImageIO must recognize a complete image source containing exactly one image, with dimensions from 1 through 4096 pixels and at most 8,388,608 pixels total. The source type must conform to `UTType.image`. A [64-pixel ImageIO thumbnail](https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex%28_%3A_%3A_%3A%29) then verifies that the compressed payload can decode; source caching is disabled so validation retains no full-resolution image. Empty, non-image, incomplete, multi-frame or oversized content fails with `HostError.invalidArtwork`. PNG and JPEG are covered by fixtures; other single-image formats depend on the platform's ImageIO support. The UI must still bound concurrent requests and retained thumbnails.

The method checks cancellation before requesting data and before/after image validation. It neither persists cover bytes nor logs image URLs, client identity material or responses. Forgetting pairing prevents subsequent artwork requests; the app cancels and invalidates pending UI work when switching hosts or removing pairing.

## Executed checks

The complete integrated Swift suite passed 69 tests (44 XCTest and 25 host tests), and the macOS app built and signed successfully. The host suite includes six artwork tests covering the exact HTTPS query, IPv6 and custom HTTPS port, reuse of authenticated server metadata, rejection of unpaired/invalid requests, certificate/permission/404/timeout propagation without HTTP fallback, cancellation, pairing removal, PNG/JPEG decoding, and malformed, truncated, multi-frame, byte-limit, dimension-limit and pixel-limit failures. Existing PIN/OTP and memory-only loopback mutual-TLS tests also passed.

```sh
swift test --disable-sandbox --manifest-cache none --filter SwiftlightHostTests
```

These tests use synthetic covers and in-memory identity stores; only the pre-existing TLS fixture opens a loopback connection. They do not access a real host, user Keychain, remote app state or GUI. Real-host cover availability and the final library appearance are separate application checks; live visual validation of this artwork update is pending. See [appearance](../appearance.md) for the UI and cache behavior.
