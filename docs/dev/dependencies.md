# Upstream dependency maintenance

The source of truth for the protocol implementation is the `Dependencies/moonlight-common-c` Git submodule. Its gitlink and `Dependencies/versions.json` pin revision `62e066388f1a1b133e0bee947b9a374311a3354b`. ENet and nanors are recursively initialized to the exact revisions selected by common-c; a system ENet is not compatible with this build. MoonlightAppleVideo is a separate immutable SwiftPM dependency and remains the only video decoder.

The selected common-c revision includes three upstream frame-loss recovery fixes beyond the local Moonlight Qt reference's `874ac954`: multi-block RFI recovery (`d85371c`), partially dropped IDR handling (`be43885`), and avoiding speculative losses when RFI is disabled (`62e0663`). These are upstream changes, not Swiftlight patches.

`scripts/prepare-common-c.py`, called by the native bootstrap, verifies the main and nested checkout revisions and rejects modified tracked upstream files. It archives only committed sources, applies each patch named in `patches/moonlight-common-c/series` with `git apply --check`, and writes the generated tree at `Sources/CStreamBridge/vendor/common-c`. That directory is ignored by Git. Despite its compatibility path name, it is generated build input, not another maintained source copy.

`Package.swift` explicitly compiles the generated common-c C files, its bundled ENet and nanors into `CStreamBridge`, alongside Swiftlight's ownership/input/audio adapters. The app statically links this target through `SwiftlightTransport`. The native sanitizer harness compiles the same generated sources. Common-c owns RTSP/SDP negotiation, encrypted streaming, video depacketization/FEC/recovery, audio transport and input transmission. The HTTP host certificate/PIN pairing flow remains in `SwiftlightHost`, following upstream clients; see `host-protocol-details.md`.

The current series contains four focused patches: cancellation/termination lifetime, Darwin clock epoch, bound video socket address, and confirmed RTP frame-outcome counters. The last observes existing receive/recovery decisions without changing them; its exact accounting and no-host packet-path tests are in [stream statistics](stream-statistics-implementation.md).

The generated `.swiftlight-source.json` records the pins, patch order and SHA-256 source/preparation digests. An unchanged bootstrap verifies those digests and preserves file modification times. A changed patch set regenerates the complete tree only after every patch applies; failures leave the previous output in place and stop the build. Never edit generated files to implement a fix.

## Updating common-c

1. Fetch the upstream submodule, review the commits, check out the chosen immutable revision, and initialize its recursive submodules.
2. Update the gitlink and matching revision/nested pins in `Dependencies/versions.json` together.
3. Review the small patch series. Remove patches fixed upstream; rebase only the still-needed changes and record their reasons in its README. Do not replace transport or pairing protocol semantics to work around integration errors.
4. Run `scripts/bootstrap-dependencies.sh`, `scripts/validate-offline.sh`, and the separate `SWIFTLIGHT_SANITIZERS=thread scripts/validate-transport-native.sh`. Build the signed bundle and run the manual host interoperability gates before claiming release validation.
5. Confirm `git -C Dependencies/moonlight-common-c status --porcelain` is empty, and review `git diff --submodule=log` plus the patch diff.

Fresh clones can use `--recurse-submodules`; bootstrap also initializes missing submodules. A wrong revision or tracked local edit is rejected with an actionable error rather than silently reset. The initial bootstrap requires Git/network access, native build tools, and the pinned SwiftPM decoder repository.
