#!/usr/bin/env python3
"""Run already-built production decoder probes sequentially in A-B-B-A order."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wrapper", type=Path, required=True)
    parser.add_argument("--direct", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--fps", type=float, default=240)
    parser.add_argument("--frames", type=int, default=480)
    parser.add_argument("--warmup", type=int, default=120)
    parser.add_argument("--depth", type=int, choices=[8, 10], default=10)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    runs = []
    for index, (label, executable) in enumerate([("wrapper", args.wrapper), ("direct", args.direct),
                                                ("direct", args.direct), ("wrapper", args.wrapper)], start=1):
        output = args.output_dir / f"{index}-{label}-{args.fps:g}.json"
        subprocess.run([str(executable.resolve()), str(args.fixture.resolve()), str(args.fps),
                        str(args.frames), str(args.warmup), str(args.depth), str(output.resolve())],
                       check=True, timeout=60)
        report = json.loads(output.read_text())
        report["variant"] = label
        report["executable_sha256"] = hashlib.sha256(executable.read_bytes()).hexdigest()
        output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        runs.append(report)
    for key in ["fixture_sha256", "rendered_rgba32float_sha256", "width", "height", "chroma",
                "bit_depth", "requested_fps", "measured_frames", "warmup_frames", "capacity"]:
        if len({str(report[key]) for report in runs}) != 1:
            raise RuntimeError(f"Comparison mismatch: {key}")
    summary = {"scope": runs[0]["scope"], "order": [run["variant"] for run in runs],
               "fixture_sha256": runs[0]["fixture_sha256"],
               "rendered_rgba32float_sha256": runs[0]["rendered_rgba32float_sha256"],
               "fps": args.fps, "frames_per_run": args.frames, "capacity": 2,
               "runs": [{"variant": run["variant"], "executable_sha256": run["executable_sha256"],
                         "summaries_ms": run["summaries_ms"], "would_block": run["would_block"],
                         "late_admissions_over_0_1_ms": run["late_admissions_over_0_1_ms"],
                         "maximum_admission_lateness_ms": run["maximum_admission_lateness_ms"],
                         "outstanding_high_water": run["outstanding_high_water"],
                         "vt_timing_samples": run["vt_timing_samples"]} for run in runs]}
    (args.output_dir / "comparison.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(args.output_dir / "comparison.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
