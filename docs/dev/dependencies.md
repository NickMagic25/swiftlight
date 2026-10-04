# Decoder and upstream dependency maintenance

The source of truth for the protocol implementation is the `Dependencies/moonlight-common-c` Git submodule. Its gitlink and `Dependencies/versions.json` pin revision `62e066388f1a1b133e0bee947b9a374311a3354b`. ENet and nanors are recursively initialized to the exact revisions selected by common-c; a system ENet is not compatible with this build. MoonlightAppleVideo is first-party source in `Packages/moonlight-apple-decoder/`, consumed as a local SwiftPM package for VideoToolbox codecs. PyroWave uses the direct native integration described below.

The selected common-c revision includes three upstream frame-loss recovery fixes beyond the local Moonlight Qt reference's `874ac954`: multi-block RFI recovery (`d85371c`), partially dropped IDR handling (`be43885`), and avoiding speculative losses when RFI is disabled (`62e0663`). These are upstream changes, not Swiftlight patches.

`scripts/prepare-common-c.py`, called by the native bootstrap, verifies the main and nested checkout revisions and rejects modified tracked upstream files. It archives only committed sources, applies each patch named in `patches/moonlight-common-c/series` with `git apply --check`, and writes the generated tree at `Sources/shared/CStreamBridge/vendor/common-c`. That directory is ignored by Git. Despite its compatibility path name, it is generated build input, not another maintained source copy.

`Package.swift` explicitly compiles the generated common-c C files, its bundled ENet and nanors into `CStreamBridge`, alongside Swiftlight's ownership/input/audio adapters. The app statically links this target through `SwiftlightTransport`. The native sanitizer harness compiles the same generated sources. Common-c owns RTSP/SDP negotiation, encrypted streaming, video depacketization/FEC/recovery, audio transport and input transmission. The HTTP host certificate/PIN pairing flow remains in `SwiftlightHost`, following upstream clients; see `host-protocol-details.md`.

The current series contains six focused patches: cancellation/termination lifetime, Darwin clock epoch, bound video socket address, confirmed RTP frame-outcome counters, PyroWave profile/record-framing transport, and per-frame transport timing milestones. The counters observe receive/recovery decisions; delivered partial PyroWave frames with unrepaired packet loss count as network loss. The fifth patch ports Nonary's protocol implementation onto the immutable upstream pin without adding its unrelated controller changes. It keeps the selected upstream's newer recovery fixes, bounds lost-packet synthesis, preserves payload boundaries for decoder recovery, and rejects explicit incompatible bitstream revisions or unavailable selected profiles. The sixth patch carries the decisive packet receipt, final FEC readiness, queue-offer time and partial-frame status with the same decode unit; it changes no queue admission or recovery policy. See the [patch rationale](../../patches/moonlight-common-c/README.md) and [transport contract](transport.md).

The generated `.swiftlight-source.json` records the pins, patch order and SHA-256 source/preparation digests. An unchanged bootstrap verifies those digests and preserves file modification times. A changed patch set regenerates the complete tree only after every patch applies; failures leave the previous output in place and stop the build. Never edit generated files to implement a fix.

## Updating common-c

1. Fetch the upstream submodule, review the commits, check out the chosen immutable revision, and initialize its recursive submodules.
2. Update the gitlink and matching revision/nested pins in `Dependencies/versions.json` together.
3. Review the small patch series. Remove patches fixed upstream; rebase only the still-needed changes and record their reasons in its README. Do not replace transport or pairing protocol semantics to work around integration errors.
4. Run `scripts/bootstrap-dependencies.sh`, `scripts/validate-offline.sh`, and the separate `SWIFTLIGHT_SANITIZERS=thread scripts/validate-transport-native.sh`. Build the signed bundle and run the manual host interoperability gates before claiming release validation.
5. Confirm `git -C Dependencies/moonlight-common-c status --porcelain` is empty, and review `git diff --submodule=log` plus the patch diff.

Fresh clones can use `--recurse-submodules`; bootstrap also initializes missing submodules. A wrong revision or tracked local edit is rejected with an actionable error rather than silently reset. The initial bootstrap requires Git/network access and native build tools. Decoder sources arrive with this repository rather than a separate SwiftPM download.

## First-party decoder package

`Packages/moonlight-apple-decoder/` contains the reusable `MoonlightAppleVideo`
C ABI, implementation, public headers, tests, fixture tools, integration
materials and documentation. The import preserves the source from decoder
commit `dd295065417344a0a5d3d240bce9060d2646851c`. Subsequent decoder and client
changes share Swiftlight's Git history. This source import does not establish
new hardware, performance or live-stream acceptance; dated reports retain the
revisions and checkout paths used for their original runs.

Both the root `Package.swift` and Xcode consume this package using the
repository-relative `Packages/moonlight-apple-decoder` path. No remote decoder
revision or decoder lockfile entry is needed. Change the implementation here,
keep its CMake and SwiftPM source lists consistent, and preserve the public
ownership and completion contract. Its standalone CMake library and SwiftPM
ownership smoke remain available for reusable-library validation and other
consumers. Sources stay outside the app target's synchronized folders.

The decoder's own `Dependencies/pyrowave` submodule remains pinned to
`488564aa2b5ffca0377938c27a1b67fce817c5b9` for its standalone PyroWave backend.
Its gitlink lives in this monorepo at
`Packages/moonlight-apple-decoder/Dependencies/pyrowave`; it is distinct from
Swiftlight's direct PyroWave submodule and revision. Bootstrap verifies both
inputs. PyroWave GPU changes belong in the fork, with the reviewed commit
published before either consumer's gitlink and version-manifest entry change.

From the Swiftlight repository root, after bootstrap:

```sh
cmake -S Packages/moonlight-apple-decoder -B .build/decoder -DCMAKE_BUILD_TYPE=Release
cmake --build .build/decoder --parallel 4
ctest --test-dir .build/decoder --output-on-failure
mkdir -p .build/ModuleCache
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
  swift run --package-path Packages/moonlight-apple-decoder \
  --scratch-path "$PWD/.build/decoder-swiftpm" --disable-sandbox --manifest-cache none \
  -c release mav-swift-smoke
```

Run the relevant Swiftlight tests and the Xcode app build after decoder changes;
video changes additionally need the applicable hardware and fixture gates.
Portable native tests and the ownership smoke do not establish hardware decode,
GPU output or visible presentation. See the [decoder guide](../../Packages/moonlight-apple-decoder/README.md)
and [client video validation](video-validation.md) for those checks.

## Direct PyroWave dependency

Swiftlight pins `Dependencies/pyrowave` to published fork commit
`56b007143b471def3e41d5e74d10f73dfc8c8df1` from
[NickMagic25/pyrowave](https://github.com/NickMagic25/pyrowave), branch
`codex/metal-improvements`. The gitlink and `Dependencies/versions.json` must
agree; the compatible streaming bitstream identity remains `186f0393`.
`scripts/verify-pyrowave.py`, invoked by bootstrap, initializes a missing
checkout and rejects a wrong revision, source URL or modified checkout without
resetting local work. The sources compile directly from the pristine submodule.

`CMetalPyrowave` builds only `pyrowave_common.mm`, `pyrowave_decoder.mm` and
`pyrowave_bitstream.cpp`. Committed shader-string headers supply the production
kernels; raw `.metal` sources, the encoder, benchmarks and private experimental
kernels are excluded from app inputs. Experiments described in the fork's
`metal/PERFORMANCE.md` remain CLI-private and do not change shared defaults.
The native decoder and outer transport-framing adapter use optimized C++ in
Debug as well as Release.

`CPyrowaveBridge` owns the bounded decoder and GPU-frame C API consumed by
`SwiftlightVideo`. Its private force-included symbol map gives the native C
symbols and C++ namespace distinct names, allowing comparison with a local
MoonlightAppleVideo package that embeds another PyroWave revision. The bridge
public header exposes no upstream types. The bridge retains outer input/framing
bounds and ownership, while PyroWave's native API owns codec parsing and decode
readiness. It does not duplicate coefficient validation. Changes to codec
acceptance or GPU decoding belong in the fork and require an intentional pin
update. `CNativeVideoABI` adapts optional
metadata/trace functions at the local VideoToolbox decoder ABI boundary.
Neither target creates another VideoToolbox session.
This direct PyroWave implementation is explicitly authorized for this feature;
MoonlightAppleVideo continues to own the VideoToolbox path.

Both Xcode and secondary SwiftPM app packaging copy
`Dependencies/pyrowave/LICENSE` into `Licenses/PyroWave.txt`; missing notices fail
packaging. A direct dependency update changes the submodule gitlink and version
manifest together. Publish the reviewed fork commit before pinning it, then
verify bootstrap and a normal app build using the in-repository decoder package.
The reusable decoder's separate PyroWave pin changes only when intentionally
updating that standalone backend.

The [September 30 report](pyrowave-submodule-2026-09-30.md) describes the previous
decoder-owned submodule checkpoint, not current dependency acceptance.

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
