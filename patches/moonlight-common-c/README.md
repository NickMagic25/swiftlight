# Swiftlight common-c patches

`Dependencies/moonlight-common-c` is the real, pristine Git submodule. Its revision and nested ENet/nanors revisions are pinned in `Dependencies/versions.json`. `scripts/prepare-common-c.py` archives committed source, verifies each pin and clean tracked content, then applies this explicit `series` into ignored `Sources/CStreamBridge/vendor/common-c`. Build and native validation entry points invoke preparation. Edit these patches rather than the generated source or upstream checkout.

The application currently selects upstream `62e066388f1a1b133e0bee947b9a374311a3354b`. These patches were extracted and audited against the earlier local Qt reference `874ac9548f1bd6f095ef2b435c42cdde460e7821`; all three pass `git apply --check` against both pins. The three newer upstream commits change only `RtpVideoQueue.c` and `VideoDepacketizer.c` (12 insertions, 6 deletions) and do not overlap the patches below. Their upstream frame-loss/recovery improvements remain intact.

| Patch | Files | Purpose and required caller contract |
|---|---|---|
| `0001-serialize-cancellation-and-termination.patch` | `src/Connection.c`, `src/Limelight-internal.h` | Use an atomic interruption flag and atomic-exchange termination arbitration; keep the single termination callback thread joinable until teardown. Stop first joins media/control callers and then termination delivery before platform cleanup. App callbacks enqueue lifecycle work and must never invoke stop inline. |
| `0002-expose-darwin-clock-epoch.patch` | `src/Platform.c` | Expose the immutable Darwin `CLOCK_UPTIME_RAW` epoch after platform initialization. The bridge converts common-c relative microseconds into the decoder's absolute monotonic nanoseconds, with less than one microsecond of quantization. |
| `0003-expose-bound-video-socket-address.patch` | `src/VideoStream.c` | Read `getsockname` on the actual video socket while the bridge's API gate prevents concurrent stop/close. This is route evidence, not an inference from a separate global network monitor. |

The source audit found changes in exactly these four files. Neither patch set substitutes transport, packet framing, FEC, encryption, congestion policy, codec negotiation or a video decoder. Existing licenses and notices remain present in the generated source. The patches may be proposed upstream separately; no upstream submission is implied.

To prepare and verify idempotently:

```sh
git submodule update --init --recursive
python3 scripts/prepare-common-c.py
python3 scripts/prepare-common-c.py
scripts/validate-transport-native.sh
SWIFTLIGHT_SANITIZERS=thread scripts/validate-transport-native.sh
```

Before the submodule migration, the owned native suite passed ASan/UBSan and TSan for exact frame completion, concurrent audio transfer, keyboard wire normalization/release, clock/permissions, deterministic cancellation phases and callback retirement. The final clean verification report records the rerun against the selected submodule revision; do not treat an earlier vendored-tree result as validation of a different upstream revision.
