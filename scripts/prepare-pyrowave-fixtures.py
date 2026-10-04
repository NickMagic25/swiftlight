#!/usr/bin/env python3
"""Build the pinned test-only Metal encoder and prepare synthetic PyroWave inputs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=Path(".build/pyrowave-fixtures"))
    parser.add_argument("--benchmark", action="store_true", help="Also encode the fixed 3440x1440 4:2:0 ramp")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    source = root / "Dependencies/pyrowave/metal"
    if not (source / "pyrowave_encoder.mm").is_file():
        parser.error("Initialize the pinned Dependencies/pyrowave submodule first")
    directory = args.output_dir.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    compiler = subprocess.check_output(["xcrun", "--find", "clang++"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    writer = root / "scripts/pyrowave-fixture-writer.mm"
    inputs = [writer, source / "pyrowave_common.mm", source / "pyrowave_encoder.mm", source / "pyrowave_bitstream.cpp"]
    executable = directory / "fixture-writer"
    environment = os.environ.copy()
    environment["CLANG_MODULE_CACHE_PATH"] = str(directory / "ModuleCache")
    command = [compiler, "-std=c++17", "-O2", "-fobjc-arc", "-isysroot", sdk, "-I", str(source),
               *map(str, inputs), "-framework", "Foundation", "-framework", "Metal", "-framework", "IOSurface", "-o", str(executable)]
    subprocess.run(command, check=True, env=environment, timeout=120)
    cases = [(128, 128, 420, 65536), (127, 97, 444, 49276)]
    if args.benchmark:
        cases.append((3440, 1440, 420, 1000000))
    fixtures = []
    # The encoder uses 8-bit normalized planes. Both 8-bit and 10-bit production
    # output profiles decode these same exact wavelet coefficients.
    for width, height, chroma, budget in cases:
        filename = f"pyrowave-{width}x{height}-{chroma}.bin"
        output = directory / filename
        subprocess.run([str(executable), str(width), str(height), str(chroma), str(budget), str(output)],
                       check=True, env=environment, timeout=60)
        fixtures.append({"file": filename, "sha256": sha256(output), "size": output.stat().st_size,
                         "width": width, "height": height, "chroma": chroma, "budget_bytes": budget})
    revision = subprocess.check_output(["git", "-C", str(source.parent), "rev-parse", "HEAD"], text=True).strip()
    manifest = {"scope": "synthetic test-only inputs; no captured media; not application dependencies",
                "encoder_revision": revision, "encoder_source_sha256": {path.name: sha256(path) for path in inputs},
                "encoder_binary_sha256": sha256(executable), "platform": platform.platform(),
                "input_pattern": "Y=32+96*x/dx+96*y/dy; Cb=64+64*x/dx+32*y/dy; Cr=160-48*x/dx+32*y/dy; integer divisions; dx=max(1,w-1),dy=max(1,h-1)",
                "fixtures": fixtures}
    (directory / "provenance.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(directory)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
