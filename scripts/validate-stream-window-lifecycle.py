#!/usr/bin/env python3
"""Exercise the production window controller with an in-memory AppKit facade."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=Path(".build/debug"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    build = args.build_dir.resolve()
    source_path = root / "Sources/SwiftlightApp/StreamWindowController.swift"
    source = source_path.read_text()
    start = "@MainActor final class StreamWindowController"
    end = "\nstruct StreamWindowReader:"
    if source.count(start) != 1 or source.count(end) != 1:
        parser.error("Production controller boundary changed; review the harness extraction")
    controller = source[source.index(start):source.index(end)]
    # Only AppKit class names change. All state, continuation, cancellation,
    # timeout and notification-handling code is the production implementation.
    controller = re.sub(r"\bNSWindow\b", "FixtureWindow", controller)
    controller = re.sub(r"\bNSApplication\b", "FixtureApplication", controller)
    controller = re.sub(r"\bNSWindowDelegate\b", "FixtureWindowDelegate", controller)
    objects = sorted((build / "SwiftlightCore.build").glob("*.swift.o"))
    description = build / "description.json"
    if not objects or not description.is_file():
        parser.error("Build Swiftlight first, or select its debug binary directory")
    commands = json.loads(description.read_text())["swiftCommands"]
    arguments = next(value["otherArguments"] for key, value in commands.items()
                     if key.startswith("C.SwiftlightCore-"))
    target = arguments[arguments.index("-target") + 1]
    swiftc = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="swiftlight-window-lifecycle-") as temporary:
        directory = Path(temporary)
        combined = directory / "WindowLifecycle.swift"
        combined.write_text("import Foundation\nimport AppKit\nimport SwiftlightCore\n" + controller + "\n" +
                            (root / "scripts/stream-window-lifecycle-harness.swift").read_text())
        executable = directory / "window-lifecycle"
        subprocess.run([swiftc, "-swift-version", "6", "-parse-as-library", "-target", target,
                        "-sdk", sdk, "-module-cache-path", str(directory / "module-cache"),
                        "-I", str(build / "Modules"), str(combined), *map(str, objects),
                        "-framework", "CoreGraphics", "-framework", "AppKit", "-o", str(executable)], check=True, timeout=120)
        environment = os.environ.copy()
        environment["SWIFTLIGHT_WINDOW_SOURCE_SHA256"] = hashlib.sha256(source_path.read_bytes()).hexdigest()
        return subprocess.run([str(executable)], env=environment, timeout=30).returncode


if __name__ == "__main__":
    raise SystemExit(main())
