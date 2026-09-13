#!/usr/bin/env python3
"""Compile the production preview plus a same-file lifecycle harness; open no UI."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=Path(".build/debug"),
                        help="Existing SwiftPM debug binary directory")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    build = args.build_dir.resolve()
    source = root / "Sources/SwiftlightApp/ReplayPreview.swift"
    objects = sorted((build / "SwiftlightVideo.build").glob("*.swift.o"))
    objects += sorted((build / "MoonlightAppleVideo.build").rglob("*.o"))
    description = build / "description.json"
    if not objects or not description.is_file():
        parser.error("Build Swiftlight first, or select its debug binary directory")
    commands = json.loads(description.read_text())["swiftCommands"]
    arguments = next(value["otherArguments"] for key, value in commands.items()
                     if key.startswith("C.SwiftlightVideo-"))
    modulemap = Path(next(arg.split("=", 1)[1] for arg in arguments
                          if arg.startswith("-fmodule-map-file=")))
    target = arguments[arguments.index("-target") + 1]
    swiftc = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="swiftlight-preview-lifecycle-") as temporary:
        directory = Path(temporary)
        fixture = json.loads((root / "fixtures/hevc-sdr8/manifest.json").read_text())
        unit = fixture["access_units"][0]
        payload = (root / "fixtures/hevc-sdr8" / fixture["payload_file"]).read_bytes()
        payload = payload[unit["offset"]:unit["offset"] + unit["length"]]
        fixture["access_units"] = [unit]
        fixture["payload_sha256"] = hashlib.sha256(payload).hexdigest()
        (directory / fixture["payload_file"]).write_bytes(payload)
        manifest = directory / "manifest.json"
        manifest.write_text(json.dumps(fixture))
        combined = directory / "PreviewLifecycle.swift"
        combined.write_text(source.read_text() + "\n" +
                            (root / "scripts/preview-lifecycle-harness.swift").read_text())
        executable = directory / "preview-lifecycle"
        command = [swiftc, "-swift-version", "6", "-parse-as-library",
                   "-target", target, "-sdk", sdk,
                   "-module-cache-path", str(directory / "module-cache"),
                   "-I", str(build / "Modules"), "-Xcc", f"-fmodule-map-file={modulemap}",
                   str(combined), *map(str, objects), "-lc++", "-o", str(executable)]
        for framework in ["AppKit", "SwiftUI", "QuartzCore", "Metal", "CoreVideo", "CoreMedia", "VideoToolbox"]:
            command += ["-framework", framework]
        subprocess.run(command, check=True, timeout=120)
        environment = os.environ.copy()
        environment["SWIFTLIGHT_PREVIEW_SOURCE_SHA256"] = hashlib.sha256(source.read_bytes()).hexdigest()
        result = subprocess.run([str(executable), str(manifest)], env=environment, timeout=30)
        return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
