# Mobile OpenSSL file-store omission

`mobile-no-file-store.patch` applies only to the extracted iOS device and
simulator builds of the SHA-256-pinned OpenSSL 3.6.4 archive. The macOS source,
configuration and libraries retain the upstream behavior.

OpenSSL registers the `file` store in both its default and base providers even
with `no-stdio` and `no-posix-io`. This registration retains the file-store
object's `stat` import in the app, although Swiftlight has no file-store calls.
OpenSSL 3.6.4 has no supported Configure option to omit this store. The patch
removes its registration from the shared `providers/stores.inc` table; static
linking can then omit the unused file-store implementation. It changes no
cipher, key, certificate, entropy, encoder or decoder implementation.

Mobile `OSSL_STORE_open(file:)` and `OSSL_STORE_attach` are unavailable after
this change. Swiftlight reads and writes certificates and keys using memory
BIOs, and its PEM key reader uses `OSSL_DECODER_from_bio` directly. Do not add a
file-store dependency without revisiting this choice.

Bootstrap checks and applies the patch with Git in an isolated extracted
source tree. Its SHA-256 participates in each mobile slice's cache identity;
changing it rebuilds the slice. The downloaded archive remains unchanged.

Validation requires the real simulator crypto probe
(`scripts/validate-mobile-crypto.sh <simulator-UDID>`), including failed
file-store fetch, identity/PKCS12, signature/tamper and AES ECB/CBC/GCM vectors.
Audit the final device app executable with `nm -u` after relinking; it must not
import `stat`, `fstat` or `lstat` from this dependency. Successful symbol checks
are evidence about this binary, not a substitute for normal signing, privacy
review or App Store Connect processing.
