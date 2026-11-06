import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("resource_analysis", Path(__file__).parents[1] / "ops" / "Analyze-YoloResources.py")
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)


def fixture():
    meta = dict(seconds=20, interval_seconds=1, expected_version="1.0.0.48", runtime_session="session", process_id=42, expected_camera_key="1280x720@30")
    rows = []
    for index in range(20):
        native = dict(processId=42, modelSha256=analysis.MODEL_SHA, inputSize=320, onDevice=True,
                      phase="running", source="camera", hr=0, cameraFrames=index * 2 + 100,
                      frameTime=index * 1000, inferenceMs=600, preprocessMs=4, captureToResultMs=610,
                      sourceWidth=1280, sourceHeight=720)
        camera = dict(key="1280x720@30", actual=dict(width=1280, height=720, fps=30),
                      videoWidth=1280, videoHeight=720, generation=1, decodedFrames=index * 30,
                      droppedFrames=0, frameCounterMethod="getVideoPlaybackQuality.totalVideoFrames")
        state = dict(version="1.0.0.48", runtimeSession="session", nativeDetector=native, cameraPreviewReady=True, cameraTelemetry=camera)
        perf = dict(CpuLoad=20, TotalPages=1000, AvailablePages=300, PageSize=4096,
                    GPUData=dict(AvailableAdapters=[dict(EnginesUtilization=[40, 70], SystemMemoryUsed=1000000)]))
        rows.append(dict(measurement=True, elapsed_ms=index * 1000, completed_elapsed_ms=index * 1000 + 30,
                         at="2026-11-05T20:00:%02d+08:00" % index, overrun_ms=0,
                         app=dict(status=200, body=state), systemperf=dict(status=200, body=perf),
                         health=dict(power=dict(body=dict(LowPowerState=False)), thermal=dict(body=dict(CurrentStage=0)))))
    return meta, rows


class ResourceEvidenceTests(unittest.TestCase):
    def test_separate_gpu_engines_and_real_counter_deltas(self):
        result, _ = analysis.summarize_round(*fixture())
        self.assertEqual(result["gpu_engines_pct"]["0"]["mean"], 40)
        self.assertEqual(result["gpu_engines_pct"]["1"]["mean"], 70)
        self.assertEqual(result["detector_fps"], 2)
        self.assertEqual(result["preview"]["observed_total_fps"], 30)

    def test_missing_or_changed_runtime_cannot_pass(self):
        for mutation in ("session", "model", "endpoint", "counter", "actual_fps"):
            meta, rows = fixture()
            if mutation == "session": rows[10]["app"]["body"]["runtimeSession"] = "other"
            if mutation == "model": rows[10]["app"]["body"]["nativeDetector"]["modelSha256"] = "0" * 64
            if mutation == "endpoint": rows[10]["systemperf"]["status"] = 503
            if mutation == "counter": rows[10]["app"]["body"]["nativeDetector"]["cameraFrames"] = 1
            if mutation == "actual_fps": rows[10]["app"]["body"]["cameraTelemetry"]["actual"]["fps"] = 15
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                analysis.summarize_round(meta, rows)

    def test_short_or_stalled_observation_cannot_pass(self):
        meta, rows = fixture()
        with self.assertRaises(ValueError): analysis.summarize_round(meta, rows[:5])
        for row in rows: row["app"]["body"]["nativeDetector"]["cameraFrames"] = 100
        with self.assertRaises(ValueError): analysis.summarize_round(meta, rows)

    def test_unavailable_video_counter_is_not_replaced_with_requested_fps(self):
        meta, rows = fixture()
        for row in rows:
            row["app"]["body"]["cameraTelemetry"]["decodedFrames"] = None
            row["app"]["body"]["cameraTelemetry"]["frameCounterMethod"] = "unavailable"
        result, _ = analysis.summarize_round(meta, rows)
        self.assertFalse(result["preview"]["available"])
        self.assertNotIn("observed_total_fps", result["preview"])

    def test_displayed_frame_rate_excludes_dropped_video_frames(self):
        meta, rows = fixture()
        for index, row in enumerate(rows):
            row["app"]["body"]["cameraTelemetry"]["droppedFrames"] = index * 6
        result, _ = analysis.summarize_round(meta, rows)
        self.assertEqual(result["preview"]["observed_total_fps"], 30)
        self.assertEqual(result["preview"]["observed_displayed_fps"], 24)

    def test_slow_real_inference_is_retained_in_a_timed_resource_trial(self):
        meta, rows = fixture()
        for index, row in enumerate(rows):
            row["app"]["body"]["nativeDetector"]["cameraFrames"] = 100 + index // 2
        result, _ = analysis.summarize_round(meta, rows)
        self.assertTrue(result["valid"])
        self.assertEqual(result["camera_inference_delta"], 9)
        self.assertTrue(result["fewer_than_30_inferences"])


if __name__ == "__main__": unittest.main()
