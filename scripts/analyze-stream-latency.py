#!/usr/bin/env python3
"""Compare SwiftLight diagnostic exports without subtracting different clock epochs."""

import argparse
from collections import Counter
import json
import math
from pathlib import Path
import statistics
import sys


METRICS = {
    "firstPacketToPresentationMilliseconds": "First packet -> presentation",
    "firstPacketToArrivalMilliseconds": "First packet -> complete-frame enqueue",
    "arrivalToAdmissionMilliseconds": "Complete-frame enqueue -> admission",
    "admissionToVTSubmitMilliseconds": "Admission -> VT submit",
    "vtSubmitToDecodeCallbackMilliseconds": "VT submit -> decode callback",
    "firstPacketToDecodeCallbackMilliseconds": "First packet -> decode callback",
    "decodeCallbackToSelectionMilliseconds": "Decode callback -> selection",
    "decodeCallbackToRenderStartMilliseconds": "Decode callback -> render start",
    "displayCallbackToRenderStartMilliseconds": "Display callback -> render start",
    "selectionToRenderStartMilliseconds": "Selection -> render start",
    "drawableAcquisitionMilliseconds": "Drawable acquisition",
    "renderCPUToCommitMilliseconds": "Render CPU -> commit",
    "commitToPresentationMilliseconds": "Commit -> presentation",
    "commitToKernelStartMilliseconds": "Commit -> CPU driver scheduling",
    "kernelSchedulingMilliseconds": "CPU driver scheduling",
    "kernelEndToScheduledCallbackMilliseconds": "Driver end -> scheduled callback",
    "commitToScheduledCallbackMilliseconds": "Commit -> scheduled callback",
    "commitToGPUStartMilliseconds": "Commit -> GPU start",
    "gpuExecutionMilliseconds": "GPU execution (same frame)",
    "gpuEndToPresentationMilliseconds": "GPU end -> presentation",
    "gpuEndToCompletedCallbackMilliseconds": "GPU end -> CPU completion callback",
    "presentationToPresentedCallbackMilliseconds": "Presentation -> CPU presented callback",
    "deadlineToCommitMilliseconds": "Deadline -> commit (signed)",
    "targetPresentationToPresentationMilliseconds": "Target -> presentation (signed)",
    "hostProcessingMilliseconds": "Host processing (separate duration)",
}
SIGNED = {"deadlineToCommitMilliseconds", "targetPresentationToPresentationMilliseconds"}
PATHS = {
    "coarse": [
        "firstPacketToDecodeCallbackMilliseconds",
        "decodeCallbackToRenderStartMilliseconds",
        "renderCPUToCommitMilliseconds",
        "commitToPresentationMilliseconds",
    ],
    "detailed": [
        "firstPacketToArrivalMilliseconds",
        "arrivalToAdmissionMilliseconds",
        "admissionToVTSubmitMilliseconds",
        "vtSubmitToDecodeCallbackMilliseconds",
        "decodeCallbackToSelectionMilliseconds",
        "selectionToRenderStartMilliseconds",
        "renderCPUToCommitMilliseconds",
        "commitToPresentationMilliseconds",
    ],
    "gpu": [
        "firstPacketToDecodeCallbackMilliseconds",
        "decodeCallbackToRenderStartMilliseconds",
        "renderCPUToCommitMilliseconds",
        "commitToGPUStartMilliseconds",
        "gpuExecutionMilliseconds",
        "gpuEndToPresentationMilliseconds",
    ],
    "commitGPU": [
        "commitToGPUStartMilliseconds",
        "gpuExecutionMilliseconds",
        "gpuEndToPresentationMilliseconds",
    ],
    "kernelScheduling": [
        "commitToKernelStartMilliseconds",
        "kernelSchedulingMilliseconds",
        "kernelEndToScheduledCallbackMilliseconds",
    ],
}
TOTAL = "firstPacketToPresentationMilliseconds"
PATH_TOTALS = {
    "commitGPU": "commitToPresentationMilliseconds",
    "kernelScheduling": "commitToScheduledCallbackMilliseconds",
}
GPU_METRICS = {
    "firstPacketToGPUEndMilliseconds": "First packet -> GPU end",
    "decodeCallbackToGPUEndMilliseconds": "Decode callback -> GPU end",
    **{key: METRICS[key] for key in [
        "firstPacketToDecodeCallbackMilliseconds", "decodeCallbackToSelectionMilliseconds",
        "decodeCallbackToRenderStartMilliseconds", "selectionToRenderStartMilliseconds",
        "drawableAcquisitionMilliseconds", "renderCPUToCommitMilliseconds",
        "commitToKernelStartMilliseconds", "kernelSchedulingMilliseconds",
        "kernelEndToScheduledCallbackMilliseconds", "commitToScheduledCallbackMilliseconds",
        "commitToGPUStartMilliseconds", "gpuExecutionMilliseconds",
        "gpuEndToCompletedCallbackMilliseconds",
    ]},
}
GPU_PATHS = {
    "firstPacketToGPUEnd": ("firstPacketToGPUEndMilliseconds", [
        "firstPacketToDecodeCallbackMilliseconds", "decodeCallbackToRenderStartMilliseconds",
        "renderCPUToCommitMilliseconds", "commitToGPUStartMilliseconds", "gpuExecutionMilliseconds",
    ]),
    "decodeCallbackToGPUEnd": ("decodeCallbackToGPUEndMilliseconds", [
        "decodeCallbackToRenderStartMilliseconds", "renderCPUToCommitMilliseconds",
        "commitToGPUStartMilliseconds", "gpuExecutionMilliseconds",
    ]),
    "kernelScheduling": ("commitToScheduledCallbackMilliseconds", PATHS["kernelScheduling"]),
}


def numeric(value, signed=False):
    return (isinstance(value, (int, float)) and not isinstance(value, bool)
            and math.isfinite(value) and (signed or value >= 0))


def percentile(ordered, fraction):
    position = (len(ordered) - 1) * fraction
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def summarize(values):
    """Linear interpolation at (n - 1) * p; no invented values for empty samples."""
    ordered = sorted(values)
    return {
        "count": len(ordered),
        "mean": statistics.fmean(ordered) if ordered else None,
        "p50": percentile(ordered, 0.50) if ordered else None,
        "p95": percentile(ordered, 0.95) if ordered else None,
        "p99": percentile(ordered, 0.99) if ordered else None,
        "minimum": ordered[0] if ordered else None,
        "maximum": ordered[-1] if ordered else None,
    }


def metric_summary(frames, key):
    valid = [frame[key] for frame in frames if numeric(frame.get(key), key in SIGNED)]
    missing = sum(frame.get(key) is None for frame in frames)
    result = summarize(valid)
    result.update(missing=missing, invalid=len(frames) - missing - len(valid), unit="ms")
    if key in SIGNED:
        result["positiveCount"] = sum(value > 0 for value in valid)
    return result


def matched_path(frames, keys, total=TOTAL):
    """All stage distributions and their total use exactly the same frames."""
    complete = [frame for frame in frames if all(numeric(frame.get(key)) for key in [total] + keys)]
    return {
        "totalMetric": total,
        "completeCount": len(complete),
        "incompleteCount": len(frames) - len(complete),
        "metricsMilliseconds": {key: summarize([frame[key] for frame in complete]) for key in [total] + keys},
        "sumMinusTotalMilliseconds": summarize([
            sum(frame[key] for key in keys) - frame[total] for frame in complete
        ]),
    }


def presentation_accounting(renderer):
    """Counters count submissions/callbacks; the bounded samples deduplicate redraws.

    Do not call submitted-minus-presented dropped frames: GPU work or presentation
    can be outstanding, and old exports lack the corresponding gauges entirely.
    """
    keys = ["submitted", "completed", "inFlight", "inFlightHighWater", "presented",
            "unconfirmedPresentation", "pendingPresentation", "pendingPresentationHighWater",
            "completedAwaitingPresentation", "presentationTimingJoinEvictions"]
    counters = {key: renderer.get(key) if numeric(renderer.get(key)) else None for key in keys}

    def residual(positive, negatives):
        values = [counters[key] for key in [positive] + negatives]
        return values[0] - sum(values[1:]) if all(value is not None for value in values) else None

    return {
        **counters,
        "submittedMinusCompletedMinusInFlight": residual("submitted", ["completed", "inFlight"]),
        "unaccountedAssumingEverySubmissionHasDrawable": residual(
            "submitted", ["presented", "unconfirmedPresentation", "pendingPresentation"]),
        "interpretation": (
            "presented and unconfirmedPresentation count drawable callbacks, including redraws; "
            "unconfirmed callbacks have no usable actual presentation time and are excluded from latency samples. "
            "inFlight ends at GPU completion; pendingPresentation ends at any presentation callback, "
            "including an unconfirmed callback. completedAwaitingPresentation is the completed-GPU subset "
            "of tracked pending presentations. Pending gauges exclude evicted diagnostic joins. "
            "Evictions and accounting residuals are not measured dropped frames; submissions without "
            "drawables also contribute to the drawable-assumption residual. Missing old-schema gauges stay null."
        ),
    }


def completed_gpu_submissions(renderer):
    frames = renderer.get("completedFrameTimings") or []
    if not isinstance(frames, list) or any(not isinstance(frame, dict) for frame in frames):
        raise ValueError("renderer.completedFrameTimings must be an array of objects")
    successful = [frame for frame in frames if frame.get("succeeded") is True]
    failed = sum(frame.get("succeeded") is False for frame in frames)
    identities = [(frame.get("generation"), frame.get("frameID"), frame.get("callbackNanoseconds")) for frame in frames]
    return {
        "available": isinstance(renderer.get("completedFrameTimings"), list),
        "submissionCount": len(frames),
        "successfulCount": len(successful),
        "failedCount": failed,
        "unknownStatusCount": len(frames) - len(successful) - failed,
        "repeatedFrameIdentityCount": len(identities) - len(set(identities)),
        "population": (
            "At most 1024 recent completed GPU submissions, including redraws and submissions "
            "without usable presentation timestamps. Metrics and matched paths below use only "
            "succeeded=true submissions; failed and unknown-status counts remain explicit. "
            "This is independent of the distinct confirmed-presentation frame population. "
            "GPU end excludes compositor/display wait and cannot stand in for presentation."
        ),
        "metricsMilliseconds": {key: metric_summary(successful, key) for key in GPU_METRICS},
        "matchedPaths": {name: matched_path(successful, keys, total) for name, (total, keys) in GPU_PATHS.items()},
        "calibrationUncertaintyNanoseconds": summarize([
            frame["calibrationUncertaintyNanoseconds"] for frame in successful
            if numeric(frame.get("calibrationUncertaintyNanoseconds"))
        ]),
    }


def cadence(frames, runtime):
    # Both ends of every subtraction are confirmed presentation timestamps in CA time.
    times = [frame["actualPresentationNanoseconds"] for frame in frames
             if numeric(frame.get("actualPresentationNanoseconds"))
             and frame["actualPresentationNanoseconds"] > 0]
    ordered = sorted(set(times))
    intervals = [(b - a) / 1_000_000 for a, b in zip(ordered, ordered[1:])]
    span = (ordered[-1] - ordered[0]) / 1_000_000_000 if len(ordered) > 1 else None
    result = {
        "timestampCount": len(times), "distinctTimestampCount": len(ordered),
        "duplicateTimestampCount": len(times) - len(ordered),
        "spanSeconds": span,
        "distinctPresentationInstantsPerSecond": (len(ordered) - 1) / span if span else None,
        "intervalMilliseconds": summarize(intervals),
    }
    refresh = runtime.get("displayRefreshHz")
    if numeric(refresh) and refresh > 0:
        grid = 1000 / refresh
        origin = "exported presentationRuntime.displayRefreshHz"
    elif intervals:
        grid = percentile(sorted(intervals), 0.10)
        origin = "inferred p10 positive interval; may be a multiple of the physical refresh period"
    else:
        return result
    multiples = [max(1, int(math.floor(interval / grid + 0.5))) for interval in intervals]
    result["referenceGrid"] = {
        "milliseconds": grid, "source": origin,
        "nearestMultipleCounts": dict(sorted(Counter(multiples).items())),
        "absoluteResidualMilliseconds": summarize([
            abs(interval - multiple * grid) for interval, multiple in zip(intervals, multiples)
        ]),
    }
    return result


def scalar_fields(value):
    return {key: item for key, item in value.items() if not isinstance(item, (dict, list))}


def analyze(path):
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError("expected a JSON object")
    renderer = data.get("renderer") or {}
    decoder = data.get("decoder") or {}
    runtime = data.get("presentationRuntime") or {}
    if not all(isinstance(value, dict) for value in (renderer, decoder, runtime)):
        raise ValueError("renderer, decoder and presentationRuntime must be objects or null")
    frames = renderer.get("presentationTimings") or []
    if not isinstance(frames, list) or any(not isinstance(frame, dict) for frame in frames):
        raise ValueError("renderer.presentationTimings must be an array of objects")
    timeline = data.get("timeline") or {}
    identities = [(frame.get("generation"), frame.get("frameID"), frame.get("callbackNanoseconds")) for frame in frames]
    duplicate_count = len(identities) - len(set(identities))
    notices = [
        "Presentation metrics use at most 1024 recent distinct frames with confirmed presentations, not a whole-session average.",
        "Individual metric rows can have different valid populations; use matchedPaths for additive comparisons.",
        "The paired GPU stages belong to each presented frame. The independent decoder/GPU arrays are separate rolling populations and must not be subtracted from presentation means.",
        "CPU scheduled/completed/presented callbacks can lag their underlying events. Callback delays and kernel scheduling overlap the main GPU path; do not add them to first-packet latency.",
        "Current settings, overlay visibility and FPS describe export time; a rolling window can still contain earlier settings or warmup frames.",
        "Confirmed drawable presentation is not physical panel scanout. No raw cross-clock subtraction is performed.",
    ]
    if data.get("schemaVersion", 0) < 4:
        notices.append("Schema before 4 lacks the new stage timings and actual presentation runtime settings.")
    if data.get("schemaVersion", 0) < 5:
        notices.append("Schema before 5 lacks same-frame GPU/kernel stages and pending-presentation accounting; missing values are not zero.")
    else:
        notices.append("Same-frame GPU/presentation samples wait for both callbacks; export can omit confirmed presentations whose GPU completion callback is still outstanding.")
    if duplicate_count:
        notices.append(f"Found {duplicate_count} repeated frame identities; rows are preserved, so inspect export validity.")
    if data.get("phase") != "streaming":
        notices.append("Export is outside streaming phase; teardown can leave the recent renderer and decoder windows farther apart.")
    if not frames and numeric(renderer.get("completed")) and renderer["completed"] > 0:
        notices.append(
            "No usable OS presentation samples were exported despite completed GPU submissions. "
            f"Unconfirmed presentation callbacks: {renderer.get('unconfirmedPresentation', 'unavailable')}. "
            "GPU completion can locate pre-display work, but does not establish first-packet-to-display latency or presentation rate."
        )
    independent = {}
    for owner, source, key in [
        ("decoder", decoder, "admissionToTerminalMilliseconds"),
        ("decoder", decoder, "singleSampleVTSubmitToCallbackMilliseconds"),
        ("renderer", renderer, "gpuMilliseconds"),
    ]:
        values = source.get(key) or []
        if not isinstance(values, list):
            raise ValueError(f"{owner}.{key} must be an array or null")
        independent[f"{owner}.{key}"] = summarize([value for value in values if numeric(value)])
    transport_keys = [
        "receivedFrames", "acquiredFrames", "acquiredBytes", "pendingVideoFrames",
        "pendingAudioMilliseconds", "audioQueuedFrames", "audioUnderrunFrames", "audioOverrunFrames",
    ]
    stream = data.get("stream") or {}
    transport_counters = {key: data.get(key) for key in transport_keys}
    transport_counters.update({key: stream.get(key) for key in ["networkLostFrames", "totalNetworkFrames"]})
    return {
        "source": str(path.resolve()), "schemaVersion": data.get("schemaVersion"),
        "timestamp": data.get("timestamp"), "phase": data.get("phase"),
        "buildConfiguration": data.get("buildConfiguration"), "appVersion": data.get("appVersion"),
        "requested": data.get("requested"), "settings": data.get("settings"),
        "presentationRuntime": data.get("presentationRuntime"),
        "renderOptions": data.get("renderOptions"),
        "statisticsOverlayVisible": data.get("statisticsOverlayVisible"),
        "inputCaptured": data.get("inputCaptured"),
        "sessionDurationSeconds": timeline.get("durationSeconds"),
        "presentationSampleCount": len(frames), "duplicateFrameIdentityCount": duplicate_count,
        "presentationMetricsMilliseconds": {key: metric_summary(frames, key) for key in METRICS},
        "matchedPaths": {name: matched_path(frames, keys, PATH_TOTALS.get(name, TOTAL)) for name, keys in PATHS.items()},
        "presentationAccounting": presentation_accounting(renderer),
        "independentGPUSubmissions": completed_gpu_submissions(renderer),
        "calibrationUncertaintyNanoseconds": summarize([
            frame["calibrationUncertaintyNanoseconds"] for frame in frames
            if numeric(frame.get("calibrationUncertaintyNanoseconds"))
        ]),
        "cadence": cadence(frames, runtime), "independentWindowsMilliseconds": independent,
        "sessionCounters": {"decoder": scalar_fields(decoder), "renderer": scalar_fields(renderer),
                            "transport": transport_counters},
        "streamSnapshot": data.get("stream"), "notices": notices,
    }


def number(value):
    return "-" if value is None else f"{value:.3f}"


def print_metrics(labels, metrics):
    print(f"{'Stage':43} {'N':>5} {'Mean':>9} {'p50':>9} {'p95':>9} {'p99':>9} {'Min':>9} {'Max':>9} {'Missing/invalid':>15}")
    for key, label in labels.items():
        row = metrics[key]
        stats = " ".join(f"{number(row[field]):>9}" for field in ["mean", "p50", "p95", "p99", "minimum", "maximum"])
        print(f"{label:43} {row['count']:5} {stats} {row['missing']:>7}/{row['invalid']:<7}")


def print_paths(paths, labels):
    for name, path in paths.items():
        print(f"Matched {name} path: {path['completeCount']} complete, {path['incompleteCount']} incomplete; "
              f"sum-minus-total mean={number(path['sumMinusTotalMilliseconds']['mean'])} ms")
        if path["completeCount"]:
            print("  Same-frame means (ms): " + ", ".join(
                f"{labels[key]}={number(value['mean'])}" for key, value in path["metricsMilliseconds"].items()))


def print_report(report):
    print(f"\n{report['source']}")
    print(f"Schema {report['schemaVersion']}; {report['timestamp']}; phase={report['phase']}; "
          f"build={report['buildConfiguration'] or 'unrecorded'}")
    print("Settings: " + json.dumps(report["settings"], sort_keys=True))
    print("Actual presentationRuntime: " + json.dumps(report["presentationRuntime"], sort_keys=True))
    print("Render options: " + json.dumps(report["renderOptions"], sort_keys=True)
          + f"; statisticsOverlayVisible={report['statisticsOverlayVisible']}; inputCaptured={report['inputCaptured']}")
    stream = report["streamSnapshot"] or {}
    print(f"Received FPS at export: {number(stream.get('receivedFramesPerSecond'))}; "
          f"requested={report['requested'] or 'unrecorded'}")
    print(f"\nRecent distinct presented-frame timings ({report['presentationSampleCount']} records; at most 1024), milliseconds:")
    print_metrics(METRICS, report["presentationMetricsMilliseconds"])
    print_paths(report["matchedPaths"], METRICS)
    gpu = report["independentGPUSubmissions"]
    print(f"\nIndependent completed GPU submissions: {gpu['submissionCount']} records; "
          f"{gpu['successfulCount']} successful, {gpu['failedCount']} failed, {gpu['unknownStatusCount']} unknown status; "
          f"exported={gpu['available']}. GPU completion is not presentation.")
    if gpu["available"]:
        print(gpu["population"])
        print_metrics(GPU_METRICS, gpu["metricsMilliseconds"])
        print_paths(gpu["matchedPaths"], GPU_METRICS)
    print("Presentation callback accounting: " + json.dumps(report["presentationAccounting"], sort_keys=True))
    print("Recent sample cadence: " + json.dumps(report["cadence"], sort_keys=True))
    print("Independent decoder/GPU windows (ms): " + json.dumps(report["independentWindowsMilliseconds"], sort_keys=True))
    print("Session counters: " + json.dumps(report["sessionCounters"], sort_keys=True))
    for notice in report["notices"]:
        print("Note: " + notice)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("exports", nargs="+", type=Path, help="one or more live/last stream JSON exports")
    parser.add_argument("--output", type=Path, help="also write all analyses to this JSON file")
    args = parser.parse_args()
    if args.output and args.output.resolve() in {path.resolve() for path in args.exports}:
        parser.error("--output must not overwrite an input export")
    reports, errors = [], []
    for path in args.exports:
        try:
            report = analyze(path)
            reports.append(report)
            print_report(report)
        except (OSError, ValueError, TypeError, AttributeError) as error:
            errors.append({"source": str(path), "error": str(error)})
            print(f"{path}: {error}", file=sys.stderr)
    if args.output:
        try:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps({"analysisVersion": 2, "reports": reports, "errors": errors}, indent=2, allow_nan=False) + "\n")
        except (OSError, ValueError) as error:
            parser.exit(1, f"Cannot write {args.output}: {error}\n")
    return int(bool(errors))


if __name__ == "__main__":
    sys.exit(main())
