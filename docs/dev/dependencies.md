# Upstream dependency maintenance

The source of truth for the protocol implementation is the `Dependencies/moonlight-common-c` Git submodule. Its gitlink and `Dependencies/versions.json` pin revision `62e066388f1a1b133e0bee947b9a374311a3354b`. ENet and nanors are recursively initialized to the exact revisions selected by common-c; a system ENet is not compatible with this build. MoonlightAppleVideo is a separate immutable SwiftPM dependency and remains the only video decoder.

The selected common-c revision includes three upstream frame-loss recovery fixes beyond the local Moonlight Qt reference's `874ac954`: multi-block RFI recovery (`d85371c`), partially dropped IDR handling (`be43885`), and avoiding speculative losses when RFI is disabled (`62e0663`). These are upstream changes, not Swiftlight patches.

`scripts/prepare-common-c.py`, called by the native bootstrap, verifies the main and nested checkout revisions and rejects modified tracked upstream files. It archives only committed sources, applies each patch named in `patches/moonlight-common-c/series` with `git apply --check`, and writes the generated tree at `Sources/shared/CStreamBridge/vendor/common-c`. That directory is ignored by Git. Despite its compatibility path name, it is generated build input, not another maintained source copy.

`Package.swift` explicitly compiles the generated common-c C files, its bundled ENet and nanors into `CStreamBridge`, alongside Swiftlight's ownership/input/audio adapters. The app statically links this target through `SwiftlightTransport`. The native sanitizer harness compiles the same generated sources. Common-c owns RTSP/SDP negotiation, encrypted streaming, video depacketization/FEC/recovery, audio transport and input transmission. The HTTP host certificate/PIN pairing flow remains in `SwiftlightHost`, following upstream clients; see `host-protocol-details.md`.

The current series contains five focused patches: cancellation/termination lifetime, Darwin clock epoch, bound video socket address, confirmed RTP frame-outcome counters, and PyroWave profile/record-framing transport. The counters observe receive/recovery decisions; delivered partial PyroWave frames with unrepaired packet loss count as network loss. The fifth patch ports Nonary's protocol implementation onto the immutable upstream pin without adding its unrelated controller changes. It keeps the selected upstream's newer recovery fixes, bounds lost-packet synthesis, preserves payload boundaries for decoder recovery, and rejects explicit incompatible bitstream revisions or unavailable selected profiles. See the [patch rationale](../../patches/moonlight-common-c/README.md) and [transport contract](transport.md).

The generated `.swiftlight-source.json` records the pins, patch order and SHA-256 source/preparation digests. An unchanged bootstrap verifies those digests and preserves file modification times. A changed patch set regenerates the complete tree only after every patch applies; failures leave the previous output in place and stop the build. Never edit generated files to implement a fix.

## Updating common-c

1. Fetch the upstream submodule, review the commits, check out the chosen immutable revision, and initialize its recursive submodules.
2. Update the gitlink and matching revision/nested pins in `Dependencies/versions.json` together.
3. Review the small patch series. Remove patches fixed upstream; rebase only the still-needed changes and record their reasons in its README. Do not replace transport or pairing protocol semantics to work around integration errors.
4. Run `scripts/bootstrap-dependencies.sh`, `scripts/validate-offline.sh`, and the separate `SWIFTLIGHT_SANITIZERS=thread scripts/validate-transport-native.sh`. Build the signed bundle and run the manual host interoperability gates before claiming release validation.
5. Confirm `git -C Dependencies/moonlight-common-c status --porcelain` is empty, and review `git diff --submodule=log` plus the patch diff.

Fresh clones can use `--recurse-submodules`; bootstrap also initializes missing submodules. A wrong revision or tracked local edit is rejected with an actionable error rather than silently reset. The initial bootstrap requires Git/network access, native build tools, and the pinned SwiftPM decoder repository.

## PyroWave in the decoder package

The decoder's PyroWave development integration uses the
`Dependencies/pyrowave` Git submodule from the public HTTPS fork
[NickMagic25/pyrowave](https://github.com/NickMagic25/pyrowave). Its baseline is
`89f7e47d4abbf650c91fae766728af866c5e32a0`; the compatible streaming bitstream
identity remains `186f0393`. The decoder compiles the selected `metal/` sources
directly. Swiftlight consumes the decoder product and copies the submodule's
`LICENSE` into its app notices; it does not build another video implementation.

For a local decoder override, initialize the decoder's submodules before any
SwiftPM or Xcode build:

```sh
git -C /absolute/decoder submodule update --init --recursive
export SWIFTLIGHT_DECODER_PATH=/absolute/decoder
scripts/bootstrap-dependencies.sh
```

Replace `/absolute/decoder` with the actual decoder checkout. Swiftlight's
bootstrap prepares its common-c and native libraries; it does not initialize
or reset an arbitrary local decoder checkout. Keep reviewable fork changes on
the intended submodule branch and inspect them before updating the gitlink;
do not reset them to make a build pass.

The integration fixes are saved locally as
`488564aa2b5ffca0377938c27a1b67fce817c5b9` on
`codex/apple-decoder-integration` in the submodule, and the decoder gitlink
references that exact commit. This checkpoint is not a published dependency
revision. Publish the reviewed fork commit first, then publish the decoder
commit containing its gitlink. Only after both are accessible
should Swiftlight update `Package.swift`, root `Package.resolved`, and the
Xcode workspace's `Package.resolved` together. Normal versioned SwiftPM
checkouts initialize nested submodules; verify the published chain with a
fresh dependency checkout and app build, with the local override unset.
Cached builds using the override do not establish that acceptance.

## iOS native libraries and OpenSSL

`scripts/bootstrap-dependencies.sh --platform ios` builds arm64 device libraries;
`--platform ios-simulator` builds arm64 and x86_64 simulator slices. The default
remains macOS. Native SDKs have separate build/install trees; the Xcode target
selects the matching library directory, while generated mobile OpenSSL headers
select their configuration using target architecture and simulator macros.
Verified license texts are always published at `.build/dependencies/licenses`
for the app's packaging phase, including clean mobile-only Cloud workers.

The mobile OpenSSL build uses memory BIOs and Apple's secure entropy source.
Its supported build flags disable stdio, POSIX file helpers, console prompts,
automatic configuration loading and external module builds. OpenSSL 3.6.4 still
registers a file store in both built-in providers despite those flags, so the
explicit [mobile patch](../../patches/openssl/README.md) removes that unused
registration from the extracted mobile source. The upstream archive stays
SHA-256-pinned, and the patch hash is part of each mobile cache identity. macOS
uses the original source and configuration.

Run `python3 -m unittest discover -s Tests/DependencyPreparation -v` for patch
application, cache invalidation and platform isolation. After bootstrapping and
booting a simulator, run `scripts/validate-mobile-crypto.sh <simulator-UDID>`.
It exercises ephemeral identity/PKCS12, signature verification and tamper
rejection, AES ECB/CBC/GCM known vectors, rejected GCM tags, and unavailable
file-store lookup. It also fails if the linked crypto probe imports filesystem
metadata APIs. Relink and audit the actual device app before accepting a
release; a standalone probe does not establish app distribution acceptance.
