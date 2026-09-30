#!/usr/bin/env python3
"""Exercise the exact app display publisher without creating a window or host."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


HARNESS = r'''
@main private struct DisplayPublicationHarness {
    @MainActor static func settle() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
    @MainActor static func main() async {
        let publisher = DisplayChangePublisher()
        let initial = DisplayGeometry.fallback
        var middle = initial; middle.content.size.width += 10
        var latest = initial; latest.content.size.width += 20
        var delivered: [(DisplayGeometry, Double)] = []
        @MainActor func receive(_ geometry: DisplayGeometry, _ headroom: Double) {
            delivered.append((geometry, headroom))
            // Model publication makes SwiftUI call updateNSView again. Stop after
            // ten deliveries to make a broken regression fail without spinning.
            if delivered.count < 10 { publisher.publish(geometry, headroom, deliver: receive) }
        }
        func check(_ value: Bool, _ description: String) {
            guard value else { print("FAIL: \(description)"); exit(1) }
        }
        for _ in 0..<1000 { publisher.publish(initial, 1, deliver: receive) }
        await settle(); await settle()
        check(delivered.count == 1, "identical and reentrant updates must publish once")
        publisher.publish(middle, 1, deliver: receive)
        publisher.publish(latest, 1, deliver: receive)
        await settle(); await settle()
        check(delivered.count == 2 && delivered.last!.0 == latest, "resize burst must deliver only its latest geometry")
        publisher.publish(latest, 2, deliver: receive)
        await settle(); await settle()
        check(delivered.count == 3 && delivered.last!.1 == 2, "headroom-only change must publish")
        publisher.publish(middle, 2, deliver: receive)
        publisher.publish(latest, 2, deliver: receive)
        await settle(); await settle()
        check(delivered.count == 3, "returning to the delivered value must cancel an intermediate change")
        publisher.publish(middle, 2, deliver: receive); publisher.clear()
        await settle()
        check(delivered.count == 3, "detach must cancel pending delivery")
        publisher.publish(latest, 2, deliver: receive)
        await settle(); await settle()
        check(delivered.count == 4, "reattach must publish even an unchanged value")
        let evidence: [String: Any] = ["status": "PASS", "mode": "display-publication-no-window",
            "sourceSHA256": CommandLine.arguments[1], "deliveries": delivered.count,
            "checks": ["duplicate and reentrant suppression", "latest resize coalescing", "headroom-only changes",
                       "superseded change suppression", "detach cancellation", "reattach publication"],
            "liveCPUComparisonMeasured": false]
        print(String(decoding: try! JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=Path(".build/debug"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    build = args.build_dir.resolve()
    source = (root / "Sources/desktop/MacStreamSurface.swift").read_text()
    publisher = source.split("@MainActor final class DisplayChangePublisher", 1)[1].split("\nstruct StreamSurface:", 1)[0]
    publisher = "@MainActor final class DisplayChangePublisher" + publisher
    commands = json.loads((build / "description.json").read_text())["swiftCommands"]
    arguments = next(value["otherArguments"] for key, value in commands.items() if key.startswith("C.SwiftlightCore-"))
    target = arguments[arguments.index("-target") + 1]
    swiftc = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="swiftlight-display-publication-") as temporary:
        directory = Path(temporary)
        combined = directory / "DisplayPublication.swift"
        combined.write_text("import Foundation\nimport SwiftlightCore\n" + publisher + HARNESS)
        executable = directory / "display-publication"
        subprocess.run([swiftc, "-swift-version", "6", "-parse-as-library", "-target", target, "-sdk", sdk,
                        "-module-cache-path", str(directory / "module-cache"), "-I", str(build / "Modules"),
                        str(combined), *map(str, sorted((build / "SwiftlightCore.build").glob("*.swift.o"))),
                        "-o", str(executable)], check=True, timeout=120)
        return subprocess.run([str(executable), hashlib.sha256(source.encode()).hexdigest()], timeout=10).returncode


if __name__ == "__main__":
    raise SystemExit(main())
