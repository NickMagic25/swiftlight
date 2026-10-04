#!/usr/bin/env python3
"""Compare SwiftLight diagnostic exports without subtracting different clock epochs."""

import argparse
from collections import Counter
import json
import math
from pathlib import Path
import statistics
import sys


DECODE_METRICS = {
    "decodeStages.admissionToPreparationStartMilliseconds": "Decode admission -> preparation",
    "decodeStages.preparationMilliseconds": "Decode CPU preparation",
    "decodeStages.preparationEndToBackendStartMilliseconds": "Preparation end -> backend entry",
    "decodeStages.backendPreparationMilliseconds": "Backend entry -> native call",
    "decodeStages.backendCallMilliseconds": "Backend native call (CPU)",
    "decodeStages.backendReturnToCallbackMilliseconds": "Backend return -> decoder callback",
    "decodeStages.backendReturnToGPUCommitMilliseconds": "Backend return -> decode GPU commit",
    "decodeStages.gpuCommitToStartMilliseconds": "Decode GPU commit -> GPU start",
    "decodeStages.gpuExecutionMilliseconds": "Decode GPU execution",
    "decodeStages.gpuEndToCallbackMilliseconds": "Decode GPU end -> decoder callback",
    "decodeStages.admissionToCallbackMilliseconds": "Decode admission -> decoder callback",
    "decodeGPUEndToRenderStartMilliseconds": "Decode GPU end -> render start",
}
DECODE_GPU_PATH = [
    "decodeStages.admissionToPreparationStartMilliseconds",
    "decodeStages.preparationMilliseconds",
    "decodeStages.preparationEndToBackendStartMilliseconds",
    "decodeStages.backendPreparationMilliseconds",
    "decodeStages.backendCallMilliseconds",
    "decodeStages.backendReturnToGPUCommitMilliseconds",
    "decodeStages.gpuCommitToStartMilliseconds",
    "decodeStages.gpuExecutionMilliseconds",
    "decodeStages.gpuEndToCallbackMilliseconds",
]
DECODE_CPU_PATH = DECODE_GPU_PATH[:5] + ["decodeStages.backendReturnToCallbackMilliseconds"]
TRANSPORT_METRICS = {
    "transportStages.firstPacketToLastRequiredPacketMilliseconds": "First packet -> decisive packet receive",
    "transportStages.lastRequiredPacketToFECReadyMilliseconds": "Decisive packet receive -> FEC ready",
    "transportStages.fecReadyToEnqueueMilliseconds": "FEC ready -> access-unit availability",
    "transportStages.enqueueToQueueOfferMilliseconds": "Availability -> transport queue offer",
    "transportStages.queueOfferToHandoffMilliseconds": "Transport queue offer -> frame handoff",
    "transportStages.handoffToAdmissionMilliseconds": "Frame handoff -> decoder admission",
    "transportStages.firstPacketToAdmissionMilliseconds": "First packet -> decoder admission",
}
TRANSPORT_PATH = list(TRANSPORT_METRICS)[:-1]
TRANSPORT_TOTAL = "transportStages.firstPacketToAdmissionMilliseconds"
METRICS = {
    **TRANSPORT_METRICS,
    **DECODE_METRICS,
    "firstPacketToPresentationMilliseconds": "First packet -> presentation",
    "firstPacketToArrivalMilliseconds": "First packet -> access-unit availability",
    "arrivalToAdmissionMilliseconds": "Access-unit availability -> admission",
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
    "transport": TRANSPORT_PATH,
    "transportAvailability": TRANSPORT_PATH[:3],
    "transportAndNativeGPU": [
        *TRANSPORT_PATH, *DECODE_GPU_PATH, "decodeCallbackToRenderStartMilliseconds",
        "renderCPUToCommitMilliseconds", "commitToGPUStartMilliseconds",
        "gpuExecutionMilliseconds", "gpuEndToPresentationMilliseconds",
    ],
    "nativeDecode": DECODE_GPU_PATH,
    "nativeCPUDecode": DECODE_CPU_PATH,
    "nativeGPU": [
        "firstPacketToArrivalMilliseconds", "arrivalToAdmissionMilliseconds",
        *DECODE_GPU_PATH, "decodeCallbackToRenderStartMilliseconds", "renderCPUToCommitMilliseconds",
        "commitToGPUStartMilliseconds", "gpuExecutionMilliseconds", "gpuEndToPresentationMilliseconds",
    ],
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
    "transport": TRANSPORT_TOTAL,
    "transportAvailability": "firstPacketToArrivalMilliseconds",
    "nativeDecode": "decodeStages.admissionToCallbackMilliseconds",
    "nativeCPUDecode": "decodeStages.admissionToCallbackMilliseconds",
    "commitGPU": "commitToPresentationMilliseconds",
    "kernelScheduling": "commitToScheduledCallbackMilliseconds",
}
GPU_METRICS = {
    **TRANSPORT_METRICS,
    **DECODE_METRICS,
    "firstPacketToGPUEndMilliseconds": "First packet -> GPU end",
    "decodeCallbackToGPUEndMilliseconds": "Decode callback -> GPU end",
    **{key: METRICS[key] for key in [
        "firstPacketToArrivalMilliseconds", "arrivalToAdmissionMilliseconds",
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
    "transport": (TRANSPORT_TOTAL, TRANSPORT_PATH),
    "transportAvailability": ("firstPacketToArrivalMilliseconds", TRANSPORT_PATH[:3]),
    "transportAndNativeGPUToRenderGPUEnd": ("firstPacketToGPUEndMilliseconds", [
        *TRANSPORT_PATH, *DECODE_GPU_PATH, "decodeCallbackToRenderStartMilliseconds",
        "renderCPUToCommitMilliseconds", "commitToGPUStartMilliseconds", "gpuExecutionMilliseconds",
    ]),
    "nativeDecode": ("decodeStages.admissionToCallbackMilliseconds", DECODE_GPU_PATH),
    "nativeCPUDecode": ("decodeStages.admissionToCallbackMilliseconds", DECODE_CPU_PATH),
    "nativeGPUToRenderGPUEnd": ("firstPacketToGPUEndMilliseconds", [
        "firstPacketToArrivalMilliseconds", "arrivalToAdmissionMilliseconds", *DECODE_GPU_PATH,
        "decodeCallbackToRenderStartMilliseconds", "renderCPUToCommitMilliseconds",
        "commitToGPUStartMilliseconds", "gpuExecutionMilliseconds",
    ]),
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
    values = [metric_value(frame, key) for frame in frames]
    valid = [value for value in values if numeric(value, key in SIGNED)]
    missing = sum(value is None for value in values)
    result = summarize(valid)
    result.update(missing=missing, invalid=len(frames) - missing - len(valid), unit="ms")
    if key in SIGNED:
        result["positiveCount"] = sum(value > 0 for value in valid)
    return result


def metric_value(frame, key):
    """Optional nested decode stages remain unavailable in older exports."""
    value = frame
    for component in key.split("."):
        if not isinstance(value, dict):
            return None
        value = value.get(component)
    return value


def matched_path(frames, keys, total=TOTAL):
    """All stage distributions and their total use exactly the same frames."""
    complete = [frame for frame in frames if all(numeric(metric_value(frame, key)) for key in [total] + keys)]
    return {
        "totalMetric": total,
        "completeCount": len(complete),
        "incompleteCount": len(frames) - len(complete),
        "metricsMilliseconds": {key: summarize([metric_value(frame, key) for frame in complete]) for key in [total] + keys},
        "sumMinusTotalMilliseconds": summarize([
            sum(metric_value(frame, key) for key in keys) - metric_value(frame, total) for frame in complete
        ]),
    }


def pearson(pairs):
    """Correlation is unavailable for fewer than two pairs or a constant axis."""
    if len(pairs) < 2:
        return None
    xs, ys = zip(*pairs)
    x_mean, y_mean = statistics.fmean(xs), statistics.fmean(ys)
    x_variance = sum((value - x_mean) ** 2 for value in xs)
    y_variance = sum((value - y_mean) ** 2 for value in ys)
    if not x_variance or not y_variance:
        return None
    return max(-1.0, min(1.0, sum(
        (x - x_mean) * (y - y_mean) for x, y in pairs
    ) / math.sqrt(x_variance * y_variance)))


def transport_payload(frames, total=TOTAL):
    """Use per-frame access-unit bytes only, never session-average payload size."""
    payload_key = "transportStages.payloadBytes"
    span_key = "transportStages.firstPacketToLastRequiredPacketMilliseconds"

    def valid_payload(value):
        return isinstance(value, int) and not isinstance(value, bool) and value > 0

    payloads = [metric_value(frame, payload_key) for frame in frames]
    valid = [value for value in payloads if valid_payload(value)]
    missing = sum(value is None for value in payloads)
    complete_frames = [frame for frame in frames
                       if metric_value(frame, "transportStages.partialFrame") is False
                       and valid_payload(metric_value(frame, payload_key))]
    correlations = {}
    for key in [span_key, "firstPacketToArrivalMilliseconds", TRANSPORT_TOTAL, total]:
        pairs = [(metric_value(frame, payload_key), metric_value(frame, key))
                 for frame in complete_frames if numeric(metric_value(frame, key))]
        correlations[key] = {
            "count": len(pairs), "excludedCount": len(frames) - len(pairs),
            "pearsonR": pearson(pairs),
            "payloadBytes": summarize([size for size, _ in pairs]),
            "milliseconds": summarize([milliseconds for _, milliseconds in pairs]),
        }
    spans = [(metric_value(frame, payload_key), metric_value(frame, span_key))
             for frame in complete_frames if numeric(metric_value(frame, span_key))
             and metric_value(frame, span_key) > 0]
    return {
        "payloadBytes": {**summarize(valid), "missing": missing,
                         "invalid": len(frames) - missing - len(valid), "unit": "bytes"},
        "partialFrameCount": sum(metric_value(frame, "transportStages.partialFrame") is True for frame in frames),
        "payloadCorrelations": correlations,
        "payloadBitsPerReceiveSpanMegabitsPerSecond": {
            **summarize([size * 8 / (milliseconds * 1000) for size, milliseconds in spans]),
            "excludedCount": len(frames) - len(spans),
        },
        "interpretation": (
            "Payload is the decoder access-unit size, excluding transport headers and FEC parity. "
            "Correlations pair bytes and durations from the same complete frame; partial or unknown "
            "frame status is excluded. A constant axis has no defined correlation. "
            "Bytes divided by the observed receive span is not wire throughput, configured bitrate, "
            "link capacity, or a serialization lower bound: the first packet has already been received, "
            "and receiver scheduling, host pacing and packet loss can affect the span. "
            "No requested bitrate or whole-session average substitutes for missing per-frame bytes. "
            "Correlation locates an association and does not establish its cause."
        ),
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
        "transportPayload": transport_payload(successful, "firstPacketToGPUEndMilliseconds"),
        "calibrationUncertaintyNanoseconds": summarize([
            frame["calibrationUncertaintyNanoseconds"] for frame in successful
            if numeric(frame.get("calibrationUncertaintyNanoseconds"))
        ]),
        "decodeGPUClockUncertaintyNanoseconds": summarize([
            metric_value(frame, "decodeStages.gpuClockUncertaintyNanoseconds") for frame in successful
            if numeric(metric_value(frame, "decodeStages.gpuClockUncertaintyNanoseconds"))
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
        "Optional decodeStages are codec-neutral CPU/native/GPU stages paired with each frame. Backend native call is VT DecodeFrame or PyroWave CPU upload/Metal encoding, not GPU execution. VT-only fields remain unavailable for PyroWave.",
        "Optional transportStages split first receive, decisive receive, final FEC-ready, access-unit availability, queue offer, frame handoff and decoder admission. Receive timestamps describe userspace receipt, not physical NIC arrival. Partial frames have no decisive-packet interval; unavailable stages remain missing.",
        "Native decode GPU clocks have their own calibration uncertainty. The decode-GPU-end to render-start interval overlaps decode GPU-end to callback and callback to render; do not add all three together.",
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
        "receivedFrames", "acquiredFrames", "acquiredBytes", "compressedStaleSkips", "pendingVideoFrames",
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
        "transportPayload": transport_payload(frames),
        "presentationAccounting": presentation_accounting(renderer),
        "independentGPUSubmissions": completed_gpu_submissions(renderer),
        "calibrationUncertaintyNanoseconds": summarize([
            frame["calibrationUncertaintyNanoseconds"] for frame in frames
            if numeric(frame.get("calibrationUncertaintyNanoseconds"))
        ]),
        "decodeGPUClockUncertaintyNanoseconds": summarize([
            metric_value(frame, "decodeStages.gpuClockUncertaintyNanoseconds") for frame in frames
            if numeric(metric_value(frame, "decodeStages.gpuClockUncertaintyNanoseconds"))
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


def print_transport_payload(payload, labels):
    sizes = payload["payloadBytes"]
    print(f"Transport access-unit bytes: N={sizes['count']}, mean={number(sizes['mean'])}, "
          f"p95={number(sizes['p95'])}, missing={sizes['missing']}, invalid={sizes['invalid']}; "
          f"partial frames={payload['partialFrameCount']}")
    for key, pair in payload["payloadCorrelations"].items():
        if pair["count"]:
            print(f"  Payload vs {labels[key]}: paired N={pair['count']}, "
                  f"excluded={pair['excludedCount']}, Pearson r={number(pair['pearsonR'])}")
    rates = payload["payloadBitsPerReceiveSpanMegabitsPerSecond"]
    if rates["count"]:
        print(f"  Payload bits / receive span: N={rates['count']}, mean={number(rates['mean'])} Mbps; "
              "excludes headers/parity and is not measured wire throughput or link capacity.")


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
    print_transport_payload(report["transportPayload"], METRICS)
    gpu = report["independentGPUSubmissions"]
    print(f"\nIndependent completed GPU submissions: {gpu['submissionCount']} records; "
          f"{gpu['successfulCount']} successful, {gpu['failedCount']} failed, {gpu['unknownStatusCount']} unknown status; "
          f"exported={gpu['available']}. GPU completion is not presentation.")
    if gpu["available"]:
        print(gpu["population"])
        print_metrics(GPU_METRICS, gpu["metricsMilliseconds"])
        print_paths(gpu["matchedPaths"], GPU_METRICS)
        print_transport_payload(gpu["transportPayload"], GPU_METRICS)
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
            args.output.write_text(json.dumps({"analysisVersion": 4, "reports": reports, "errors": errors}, indent=2, allow_nan=False) + "\n")
        except (OSError, ValueError) as error:
            parser.exit(1, f"Cannot write {args.output}: {error}\n")
    return int(bool(errors))


if __name__ == "__main__":
    sys.exit(main())
