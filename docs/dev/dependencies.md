# Upstream dependency maintenance

The source of truth for the protocol implementation is the explicit source lock in `Dependencies/versions.json`. It pins common-c at `62e066388f1a1b133e0bee947b9a374311a3354b`, and also pins its required ENet and nanors sources by URL and commit. A system ENet is not compatible with this build. MoonlightAppleVideo is a separate immutable SwiftPM dependency and remains the only video decoder.

The selected common-c revision includes three upstream frame-loss recovery fixes beyond the local Moonlight Qt reference's `874ac954`: multi-block RFI recovery (`d85371c`), partially dropped IDR handling (`be43885`), and avoiding speculative losses when RFI is disabled (`62e0663`). These are upstream changes, not Swiftlight patches.

`scripts/prepare-common-c.py`, called by the native bootstrap, clones the locked public sources into `.build/dependency-sources/`, verifies every main and nested checkout revision, and rejects modified tracked upstream files. It archives only committed sources, applies each patch named in `patches/moonlight-common-c/series` with `git apply --check`, and writes the generated tree at `Sources/CStreamBridge/vendor/common-c`. Both directories are ignored by Git. Despite its compatibility path name, the generated tree is build input, not another maintained source copy.

There is intentionally no Git submodule in Swiftlight. This keeps Xcode Cloud's source-control integration scoped to `NickMagic25/swiftlight`; the Cloud post-clone script obtains the public, commit-pinned protocol sources itself.

`Package.swift` explicitly compiles the generated common-c C files, its bundled ENet and nanors into `CStreamBridge`, alongside Swiftlight's ownership/input/audio adapters. The app statically links this target through `SwiftlightTransport`. The native sanitizer harness compiles the same generated sources. Common-c owns RTSP/SDP negotiation, encrypted streaming, video depacketization/FEC/recovery, audio transport and input transmission. The HTTP host certificate/PIN pairing flow remains in `SwiftlightHost`, following upstream clients; see `host-protocol-details.md`.

The current series contains four focused patches: cancellation/termination lifetime, Darwin clock epoch, bound video socket address, and confirmed RTP frame-outcome counters. The last observes existing receive/recovery decisions without changing them; its exact accounting and no-host packet-path tests are in [stream statistics](stream-statistics-implementation.md).

The generated `.swiftlight-source.json` records the pins, patch order and SHA-256 source/preparation digests. An unchanged bootstrap verifies those digests and preserves file modification times. A changed patch set regenerates the complete tree only after every patch applies; failures leave the previous output in place and stop the build. Never edit generated files to implement a fix.

## Updating common-c

1. Fetch the upstream repositories, review the commits, and choose immutable revisions for common-c and its required nested sources.
2. Update the source URLs and matching revision/nested pins in `Dependencies/versions.json` together.
3. Review the small patch series. Remove patches fixed upstream; rebase only the still-needed changes and record their reasons in its README. Do not replace transport or pairing protocol semantics to work around integration errors.
4. Run `scripts/bootstrap-dependencies.sh`, `scripts/validate-offline.sh`, and the separate `SWIFTLIGHT_SANITIZERS=thread scripts/validate-transport-native.sh`. Build the signed bundle and run the manual host interoperability gates before claiming release validation.
5. Confirm `git -C .build/dependency-sources/moonlight-common-c status --porcelain` is empty, and review the source-lock and patch diffs.

Fresh clones need no submodule options. A wrong revision or tracked edit in the local source cache is rejected with an actionable error rather than silently reset. The initial bootstrap requires Git/network access, native build tools, and the pinned SwiftPM decoder repository.
