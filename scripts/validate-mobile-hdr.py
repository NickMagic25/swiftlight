#!/usr/bin/env python3
"""Validate the exact mobile HDR layer adapter with native Apple layer objects.

This checks native layer configuration, caching, and transitions. It does not
render pixels or verify physical HDR luminance, tone mapping, or Direct mode.
Use --platform macos for native property tests when a simulator reports that
CAEDRMetadata is unavailable. Unsupported capability is reported as BLOCKED.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


HARNESS = r'''
@MainActor private extension MobileHDRLayerState {
    var testMetadata: HDRMetadataValue? { metadataState.value }
}
private struct HarnessFailure: Error { let description: String }
private struct HarnessBlocked: Error { let description: String }
@main private struct MobileHDRHarness {
    @MainActor static func main() {
        var checks: [String] = []
        func check(_ value: Bool, _ description: String) throws {
            guard value else { throw HarnessFailure(description: description) }
            checks.append(description)
        }
        func colorSpace(_ layer: CAMetalLayer, _ name: CFString) -> Bool {
            guard let actual = layer.colorspace, let expected = CGColorSpace(name: name) else { return false }
            return CFEqual(actual, expected)
        }
        var evidence: [String: Any] = ["mode": "native-mobile-HDR-layer-state",
            "liveVideoTested": false, "hdrLuminanceTested": false,
            "systemToneMappingTested": false, "directPresentationVerified": false,
            "nativeEDRMetadataAvailable": CAEDRMetadata.isAvailable]
        do {
            var state = MobileHDRLayerState()
            let layer = CAMetalLayer()
            layer.pixelFormat = .rgba16Float
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            let hdr = VideoColor(primaries: 9, transfer: 16, matrix: 9,
                mastering: [0x8a,0x48,0x39,0x08,0x42,0x68,0x9b,0xaa,0x19,0x96,0x08,0xfc,
                            0x3d,0x13,0x40,0x42,0x00,0x98,0x96,0x80,0x00,0x00,0x00,0x32],
                contentLight: [0x03,0xe8,0x01,0x90])
            try check(!state.apply(color: VideoColor(), to: layer), "fresh SDR defaults require no drawable transition")
            if !CAEDRMetadata.isAvailable {
                var rejected = false
                do { _ = try state.apply(color: hdr, to: layer) }
                catch RendererFailure.unavailable { rejected = true }
                try check(rejected && layer.edrMetadata == nil && !layer.wantsExtendedDynamicRangeContent &&
                          layer.pixelFormat == .rgba16Float && state.hdrPresentationMode == .systemToneMapped,
                          "unavailable HDR capability rejects before layer mutation")
                throw HarnessBlocked(description: "Native CAEDRMetadata unavailable; HDR transitions require a capable runtime")
            }
            try check(state.apply(color: hdr, to: layer), "default HDR enables system tone mapping")
            try check(layer.wantsExtendedDynamicRangeContent && layer.edrMetadata != nil &&
                      layer.pixelFormat == .rgba16Float && colorSpace(layer, CGColorSpace.extendedLinearSRGB),
                      "baseline retains float linear HDR configuration")
            try check(state.testMetadata == HDRMetadataValue(color: hdr), "baseline retains mastering and content-light bytes")
            let original = layer.edrMetadata!
            try check(!state.apply(color: hdr, to: layer) && layer.edrMetadata === original,
                      "unchanged baseline reuses metadata without drawable transition")

            try check(state.apply(color: hdr, to: layer, hdrPresentationMode: .linearUnmapped),
                      "same-color baseline to linear-unmapped changes layer policy")
            try check(layer.wantsExtendedDynamicRangeContent && layer.edrMetadata == nil &&
                      layer.pixelFormat == .rgba16Float && colorSpace(layer, CGColorSpace.extendedLinearSRGB),
                      "linear-unmapped keeps HDR and linear float format with metadata cleared")
            try check(!state.apply(color: hdr, to: layer, hdrPresentationMode: .linearUnmapped),
                      "unchanged linear-unmapped has no repeated drawable transition")
            try check(state.apply(color: hdr, to: layer) && layer.edrMetadata != nil &&
                      state.hdrPresentationMode == .systemToneMapped,
                      "same-color return to baseline reinstalls system metadata")

            try check(state.apply(color: hdr, to: layer, hdrPresentationMode: .nativePQ),
                      "same-color native PQ switches packed output")
            try check(state.outputColorSpace == .rec2020PQ && state.hdrPresentationMode == .nativePQ &&
                      layer.wantsExtendedDynamicRangeContent && layer.edrMetadata == nil &&
                      layer.pixelFormat == .bgr10a2Unorm && colorSpace(layer, CGColorSpace.itur_2100_PQ),
                      "native PQ matches BT2020 PQ color space without linear tone-mapping metadata")
            try check(!state.apply(color: hdr, to: layer, hdrPresentationMode: .nativePQ),
                      "unchanged native PQ has no repeated drawable transition")
            try check(state.apply(color: hdr, to: layer, hdrPresentationMode: .linearUnmapped) &&
                      state.outputColorSpace == .linearSRGB && layer.edrMetadata == nil &&
                      layer.pixelFormat == .rgba16Float && colorSpace(layer, CGColorSpace.extendedLinearSRGB),
                      "native PQ to linear-unmapped restores float linear format")

            for color in [VideoColor(primaries: 1, transfer: 16, matrix: 9),
                          VideoColor(primaries: 9, transfer: 16, matrix: 1),
                          VideoColor(primaries: 9, transfer: 1, matrix: 9)] {
                _ = try state.apply(color: color, to: layer, hdrPresentationMode: .nativePQ)
                try check(state.outputColorSpace == .linearSRGB && state.hdrPresentationMode == .systemToneMapped &&
                          layer.pixelFormat == .rgba16Float,
                          "nonmatching PQ signaling remains on system-linear output")
            }
            _ = try state.apply(color: hdr, to: layer, hdrPresentationMode: .nativePQ)
            try check(state.apply(color: VideoColor(), to: layer, hdrPresentationMode: .nativePQ) &&
                      !layer.wantsExtendedDynamicRangeContent && layer.edrMetadata == nil &&
                      state.outputColorSpace == .linearSRGB && state.hdrPresentationMode == .systemToneMapped &&
                      layer.pixelFormat == .rgba16Float && colorSpace(layer, CGColorSpace.extendedLinearSRGB),
                      "PQ to SDR restores baseline format and disables HDR")
            try check(!state.apply(color: VideoColor(), to: layer, hdrPresentationMode: .linearUnmapped),
                      "debug modes do not change stable SDR layer configuration")

            _ = try state.apply(color: hdr, to: layer)
            let retained = layer.edrMetadata!
            for invalid in [VideoColor(primaries: 9, transfer: 16, matrix: 9, mastering: [1]),
                            VideoColor(primaries: 9, transfer: 16, matrix: 9, contentLight: [1])] {
                var rejected = false
                do { _ = try state.apply(color: invalid, to: layer) }
                catch RendererFailure.unsupportedColor { rejected = true }
                try check(rejected && layer.edrMetadata === retained && state.hdrPresentationMode == .systemToneMapped,
                          "invalid baseline HDR10 metadata rejects before layer mutation")
            }
            // Unmapped modes never submit these bytes to the system tone mapper.
            _ = try state.apply(color: hdr, to: layer, hdrPresentationMode: .nativePQ)
            state.reset(layer)
            try check(!layer.wantsExtendedDynamicRangeContent && layer.edrMetadata == nil &&
                      state.outputColorSpace == .linearSRGB && state.hdrPresentationMode == .systemToneMapped &&
                      layer.pixelFormat == .rgba16Float && colorSpace(layer, CGColorSpace.extendedLinearSRGB),
                      "reset retires native PQ layer state")
            try check(!state.apply(color: VideoColor(), to: layer), "reset SDR remains a no-op")
            _ = try state.apply(color: hdr, to: layer, hdrPresentationMode: .linearUnmapped)
            state.reset(layer)
            try check(state.hdrPresentationMode == .systemToneMapped && !layer.wantsExtendedDynamicRangeContent &&
                      layer.edrMetadata == nil, "reset retires linear-unmapped layer state")
            evidence["status"] = "PASS"
        } catch let error as HarnessBlocked {
            evidence["status"] = "BLOCKED"; evidence["reason"] = error.description
        } catch {
            evidence["status"] = "FAIL"
            evidence["failure"] = (error as? HarnessFailure)?.description ?? String(describing: error)
        }
        evidence["checks"] = checks
        print("HDR_LAYER_RESULT " + String(decoding: try! JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]), as: UTF8.self))
        exit(evidence["status"] as? String == "PASS" ? 0 : evidence["status"] as? String == "BLOCKED" ? 2 : 1)
    }
}
'''


def declaration(source, prefix):
    start = source.index(prefix)
    opening = source.index("{", start)
    depth = 1
    for offset in range(opening + 1, len(source)):
        if source[offset] == "{":
            depth += 1
        elif source[offset] == "}":
            depth -= 1
            if not depth:
                return source[start:offset + 1] + "\n"
    raise ValueError(f"Unterminated declaration: {prefix}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulator", nargs="?", help="Booted iPhone or iPad simulator UDID")
    parser.add_argument("--platform", choices=("ios-simulator", "macos"), default="ios-simulator")
    args = parser.parse_args()
    if args.platform == "ios-simulator" and not args.simulator:
        parser.error("ios-simulator requires a booted simulator UDID")
    root = Path(__file__).resolve().parent.parent
    inputs = {name: (root / name).read_text() for name in (
        "Sources/mobile/MobileHDRSupport.swift", "Sources/shared/SwiftlightCore/StreamSettings.swift",
        "Sources/shared/SwiftlightVideo/HDRMetadataState.swift", "Sources/shared/SwiftlightVideo/VideoDecoder.swift",
        "Sources/shared/SwiftlightVideo/MetalVideoRenderer.swift")}
    video = inputs["Sources/shared/SwiftlightVideo/VideoDecoder.swift"]
    color = "public struct VideoColor:" + video.split("public struct VideoColor:", 1)[1].split(
        "    init(_ value: mav_color)", 1)[0] + "}\n"
    renderer = inputs["Sources/shared/SwiftlightVideo/MetalVideoRenderer.swift"]
    combined = "import Foundation\nimport CoreVideo\nimport Metal\nimport QuartzCore\n" + color
    combined += inputs["Sources/shared/SwiftlightVideo/HDRMetadataState.swift"]
    combined += declaration(inputs["Sources/shared/SwiftlightCore/StreamSettings.swift"], "public enum HDRPresentationMode:")
    combined += declaration(renderer, "public enum VideoOutputColorSpace:")
    combined += declaration(renderer, "public enum RendererFailure:")
    combined += declaration(inputs["Sources/mobile/MobileHDRSupport.swift"], "@MainActor struct MobileHDRLayerState")
    combined += HARNESS
    sdk_name = "iphonesimulator" if args.platform == "ios-simulator" else "macosx"
    sdk = subprocess.check_output(["xcrun", "--sdk", sdk_name, "--show-sdk-path"], text=True).strip()
    architecture = subprocess.check_output(["uname", "-m"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="swiftlight-mobile-hdr-") as temporary:
        directory = Path(temporary)
        swift = directory / "MobileHDRHarness.swift"
        swift.write_text(combined)
        cache = root / ".build/mobile-hdr-module-cache"
        cache.mkdir(parents=True, exist_ok=True)
        executable = directory / "MobileHDRHarness"
        target = f"{architecture}-apple-ios26.0-simulator" if args.platform == "ios-simulator" else f"{architecture}-apple-macos26.0"
        subprocess.run(["xcrun", "--sdk", sdk_name, "swiftc", "-swift-version", "6", "-parse-as-library",
                        "-target", target, "-sdk", sdk,
                        "-module-cache-path", str(cache), str(swift), "-o", str(executable)], check=True, timeout=120)
        command = ["xcrun", "simctl", "spawn", args.simulator, str(executable)] if args.platform == "ios-simulator" else [str(executable)]
        run = subprocess.run(command, capture_output=True, text=True, timeout=30)
        print(run.stdout, end="")
        if run.stderr:
            print(run.stderr, end="")
        marker = next((line.split("HDR_LAYER_RESULT ", 1)[1] for line in run.stdout.splitlines()
                       if "HDR_LAYER_RESULT " in line), None)
        if marker is None:
            return run.returncode or 1
        evidence = json.loads(marker)
        evidence["simulator"] = args.simulator
        evidence["platform"] = args.platform
        evidence["sourceSHA256"] = {name: hashlib.sha256(value.encode()).hexdigest() for name, value in inputs.items()}
        evidence["harnessSHA256"] = hashlib.sha256(combined.encode()).hexdigest()
        print(json.dumps(evidence, indent=2, sort_keys=True))
        return 2 if evidence["status"] == "BLOCKED" else 0 if evidence["status"] == "PASS" and run.returncode == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
