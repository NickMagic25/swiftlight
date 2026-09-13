#!/usr/bin/env python3
"""Generate real AV1 hidden/show-existing fixtures without changing the decoder checkout.

Pattern and encoder parameters adapted from moonlight-apple-decoder's
scripts/test-av1-accounting.py (GPL-3.0); synthetic pixels are original
test data. A pinned development-only parser splits complete coded-frame units.
"""
import argparse
import array
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
PIN = "8d92ee039dc19fe50dc0158d5098d4c5646c6a56"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def source(path, depth):
    with path.open("wb") as output:
        for frame in range(48):
            samples = [32 + (x + y + frame * 3) % 160 if (x - frame) % 64 > 8 else 220
                       for y in range(144) for x in range(256)]
            samples += [100] * 9216 + [140] * 9216
            if depth == 8:
                output.write(bytes(samples))
            else:
                values = array.array("H", (sample * 4 for sample in samples))
                if sys.byteorder != "little":
                    values.byteswap()
                output.write(values.tobytes())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--decoder", type=pathlib.Path, default=ROOT.parent / "moonlight-apple-decoder")
    options = parser.parse_args()
    decoder = options.decoder.resolve()
    revision = subprocess.check_output(["git", "-C", str(decoder), "rev-parse", "HEAD"], text=True).strip()
    if revision != PIN:
        raise SystemExit(f"Expected decoder revision {PIN}, got {revision}")
    encoder = decoder / ".local/aom-build/aomenc"
    with tempfile.TemporaryDirectory(prefix="swiftlight-av1-fixtures-") as temporary:
        temp = pathlib.Path(temporary)
        splitter = temp / "av1-split"
        subprocess.run(["xcrun", "clang++", "-std=c++20", "-O2", "-I", str(decoder / "src"),
                        str(ROOT / "scripts/generate-fixtures-av1-split.cpp"), str(decoder / "src/bitstream.cpp"),
                        "-o", str(splitter)], check=True)
        for depth in (8, 10):
            raw, encoded = temp / "source.yuv", temp / "encoded.ivf"
            source(raw, depth)
            args = ["--codec=av1", "--ivf", "--i420", "--passes=1", "--usage=0", "--cpu-used=6", "--threads=2",
                    "--lag-in-frames=25", "--auto-alt-ref=1", "--min-gf-interval=16", "--max-gf-interval=16",
                    "--gf-min-pyr-height=4", "--gf-max-pyr-height=4", "--end-usage=q", "--cq-level=24",
                    "--disable-warning-prompt", "--width=256", "--height=144", "--fps=30/1", "--limit=48",
                    f"--bit-depth={depth}", f"--input-bit-depth={depth}", "--kf-max-dist=48", "--kf-min-dist=48",
                    "--color-primaries=bt709", "--transfer-characteristics=bt709", "--matrix-coefficients=bt709",
                    "--chroma-sample-position=vertical", f"--output={encoded}", str(raw)]
            subprocess.run([str(encoder), *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            units = json.loads(subprocess.check_output([str(splitter), str(encoded)], text=True))
            if not any(not x["display"] for x in units) or not any(x["existing"] for x in units):
                raise SystemExit("Encoder did not produce required hidden/show-existing coverage")
            data = encoded.read_bytes()
            payload = bytearray()
            access_units = []
            displayed = 0
            for index, unit in enumerate(units):
                chunk = data[unit["offset"]:unit["offset"] + unit["length"]]
                access_units.append({"frame_id": index, "offset": len(payload), "length": len(chunk), "sha256": sha(chunk),
                                     "pts": displayed, "dts": index, "duration": 1, "random_access": bool(unit["random_access"]),
                                     "discontinuity": False, "expected_display_count": unit["display"],
                                     "expected_show_existing": unit["existing"]})
                displayed += unit["display"]
                payload.extend(chunk)
            destination = ROOT / f"fixtures/av1-accounting-{depth}"
            destination.mkdir(parents=True, exist_ok=True)
            (destination / "payload.bin").write_bytes(payload)
            manifest = {"schema_version": 1, "codec": "av1", "profile": 0, "bit_depth": depth, "chroma": "420",
                        "width": 256, "height": 144, "framing": "av1-low-overhead-obu", "frame_rate": {"num": 30, "den": 1},
                        "timebase": {"num": 1, "den": 30}, "variant": "sdr-accounting", "payload_file": "payload.bin",
                        "payload_sha256": sha(payload), "access_units": access_units,
                        "expected_internal_samples": len(units), "expected_show_existing": sum(x["existing"] for x in units),
                        "expected_no_display": sum(not x["display"] for x in units),
                        "color": {"primaries": 1, "transfer": 1, "matrix": 1, "full_range": False},
                        "generator": {"name": "generate-fixtures-accounting.py", "decoder_revision": revision,
                                      "source_sha256": sha(raw.read_bytes()), "ivf_sha256": sha(data),
                                      "encoder_binary_sha256": sha(encoder.read_bytes()), "encoder_arguments": args[:-2],
                                      "pattern": "48-frame translating stripes, 256x144, constant U100 V140"}}
            (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
            print(f"Generated {depth}-bit: {len(units)} inputs, {displayed} display, {manifest['expected_no_display']} hidden, {manifest['expected_show_existing']} show-existing")


if __name__ == "__main__":
    main()
