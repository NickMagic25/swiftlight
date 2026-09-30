import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("analyze_stream_latency", ROOT / "scripts/analyze-stream-latency.py")
ANALYZER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ANALYZER)


def frame():
    return {
        "frameID": 31, "generation": 9, "callbackNanoseconds": 20_000_000,
        "actualPresentationNanoseconds": 100_006_000_000,
        "firstPacketToPresentationMilliseconds": 21,
        "firstPacketToArrivalMilliseconds": 3, "arrivalToAdmissionMilliseconds": 2,
        "firstPacketToDecodeCallbackMilliseconds": 15,
        "decodeCallbackToRenderStartMilliseconds": 1, "renderCPUToCommitMilliseconds": 1,
        "commitToPresentationMilliseconds": 4, "commitToGPUStartMilliseconds": 1,
        "gpuExecutionMilliseconds": 1, "gpuEndToPresentationMilliseconds": 2,
        "decodeGPUEndToRenderStartMilliseconds": 3,
        "decodeStages": {
            "admissionToPreparationStartMilliseconds": 0, "preparationMilliseconds": 1,
            "preparationEndToBackendStartMilliseconds": 1, "backendPreparationMilliseconds": 1,
            "backendCallMilliseconds": 1, "backendReturnToCallbackMilliseconds": 6,
            "backendReturnToGPUCommitMilliseconds": 1, "gpuCommitToStartMilliseconds": 1,
            "gpuExecutionMilliseconds": 2, "gpuEndToCallbackMilliseconds": 2,
            "admissionToCallbackMilliseconds": 10, "gpuClockUncertaintyNanoseconds": 25,
        },
    }


class StreamLatencyAnalysisTests(unittest.TestCase):
    def analyze(self, frames, gpu=None):
        payload = {"schemaVersion": 5, "phase": "streaming", "renderer": {"presentationTimings": frames}}
        if gpu is not None:
            payload["renderer"]["completedFrameTimings"] = gpu
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.json"
            path.write_text(json.dumps(payload))
            return ANALYZER.analyze(path)

    def test_native_and_render_paths_reconcile_on_the_same_frames(self):
        sample = frame()
        gpu = {**sample, "succeeded": True, "firstPacketToGPUEndMilliseconds": 19,
               "decodeCallbackToGPUEndMilliseconds": 4}
        gpu.pop("actualPresentationNanoseconds")
        report = self.analyze([sample], [gpu])
        for name in ["nativeDecode", "nativeCPUDecode", "nativeGPU", "coarse", "gpu"]:
            path = report["matchedPaths"][name]
            self.assertEqual(path["completeCount"], 1)
            self.assertEqual(path["sumMinusTotalMilliseconds"]["mean"], 0)
        independent = report["independentGPUSubmissions"]
        self.assertEqual(independent["matchedPaths"]["nativeGPUToRenderGPUEnd"]["completeCount"], 1)
        self.assertEqual(independent["matchedPaths"]["nativeGPUToRenderGPUEnd"]["sumMinusTotalMilliseconds"]["mean"], 0)
        self.assertEqual(report["decodeGPUClockUncertaintyNanoseconds"]["mean"], 25)
        self.assertEqual(independent["decodeGPUClockUncertaintyNanoseconds"]["mean"], 25)
        self.assertEqual(report["presentationMetricsMilliseconds"]["decodeStages.gpuExecutionMilliseconds"]["mean"], 2)
        self.assertEqual(report["presentationMetricsMilliseconds"]["gpuExecutionMilliseconds"]["mean"], 1)

    def test_older_export_stages_stay_missing_without_substituting_vt_or_other_frames(self):
        complete = frame()
        older = frame(); older["frameID"] = 32
        older.pop("decodeStages"); older.pop("decodeGPUEndToRenderStartMilliseconds")
        older["admissionToVTSubmitMilliseconds"] = 4
        older["vtSubmitToDecodeCallbackMilliseconds"] = 6
        report = self.analyze([complete, older])
        self.assertEqual(report["matchedPaths"]["coarse"]["completeCount"], 2)
        self.assertEqual(report["matchedPaths"]["nativeGPU"]["completeCount"], 1)
        self.assertEqual(report["matchedPaths"]["nativeGPU"]["incompleteCount"], 1)
        metric = report["presentationMetricsMilliseconds"]["decodeStages.backendCallMilliseconds"]
        self.assertEqual((metric["count"], metric["missing"], metric["invalid"]), (1, 1, 0))
        legacy = self.analyze([older])
        self.assertIsNone(legacy["presentationMetricsMilliseconds"]["decodeStages.backendCallMilliseconds"]["mean"])
        self.assertIsNone(legacy["decodeGPUClockUncertaintyNanoseconds"]["mean"])

    def test_invalid_nested_values_exclude_the_entire_matched_path(self):
        samples = []
        for value in [-1, True, "NaN"]:
            sample = frame(); sample["frameID"] += len(samples)
            sample["decodeStages"]["backendCallMilliseconds"] = value
            samples.append(sample)
        report = self.analyze(samples)
        metric = report["presentationMetricsMilliseconds"]["decodeStages.backendCallMilliseconds"]
        self.assertEqual((metric["count"], metric["missing"], metric["invalid"]), (0, 0, 3))
        self.assertEqual(report["matchedPaths"]["nativeGPU"]["completeCount"], 0)
        self.assertEqual(report["matchedPaths"]["coarse"]["completeCount"], 3)
        self.assertIsNone(ANALYZER.metric_value({"decodeStages": None}, "decodeStages.backendCallMilliseconds"))

    def test_mismatched_path_residuals_and_failed_gpu_submissions_remain_explicit(self):
        sample = frame(); sample["decodeStages"]["backendCallMilliseconds"] = 2
        failed = {**sample, "succeeded": False, "firstPacketToGPUEndMilliseconds": 19}
        report = self.analyze([sample], [failed])
        self.assertEqual(report["matchedPaths"]["nativeDecode"]["sumMinusTotalMilliseconds"]["mean"], 1)
        independent = report["independentGPUSubmissions"]
        self.assertEqual(independent["failedCount"], 1)
        self.assertEqual(independent["matchedPaths"]["nativeDecode"]["completeCount"], 0)
        self.assertEqual(independent["metricsMilliseconds"]["decodeStages.backendCallMilliseconds"]["count"], 0)


if __name__ == "__main__":
    unittest.main()
