# Swiftlight development documentation

This directory contains engineering notes, implementation references, validation records, benchmark procedures, dependency maintenance, and release/signing instructions. These documents may describe incomplete experiments or environment-specific validation and are not a substitute for the user guide.

## Engineering references

- [Release CI, signing secrets, and DMG distribution](releases.md)
- [Xcode Cloud and App Store Connect migration](xcode-cloud.md)
- [Architecture](architecture.md)
- [Transport and ownership](transport.md)
- [Video lifetime](video-lifetime.md)
- [Stream statistics implementation](stream-statistics-implementation.md)
- [Audio implementation](audio-implementation.md)
- [Diagnostic export schema](diagnostic-exports-schema.md)
- [Host artwork protocol](host-artwork-protocol.md)
- [Host protocol details](host-protocol-details.md)
- [Verified assumptions](verified-assumptions.md)

## Validation and investigations

- [Acceptance matrix](acceptance-matrix.md)
- [Benchmarking](benchmarking.md)
- [Implementation report](implementation-report.md)
- [Manual validation](manual-validation.md)
- [Video validation](video-validation.md)
- [Pairing follow-up](pairing-fix-validation.md)
- [Presentation latency investigation](latency-optimization-2026-09-13.md)
- [Stream latency debugging](stream-latency-debugging.md)
- [Stream deadlock validation](stream-deadlock-validation.md)
- [Statistics overlay validation](statistics-metal-overlay-2026-09-13.md)
- [Statistics and shortcut validation](stream-statistics-validation.md)
- [Compatibility matrix snapshot](compatibility-matrix.md)

Validation artifacts and generated reports are under [`validation/`](validation/). Scripts used by those checks remain under [`scripts/`](../../scripts/).
