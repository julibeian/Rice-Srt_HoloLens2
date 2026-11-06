"""Independent completion and package/data identity audit for the camera experiment."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import zipfile

MODEL = "e6b6d2f6baaae3b7970f1a4e425f2c2347a90fe6aab34c3da0aed738fcf1b048"
NATIVE = "6d9e91e1bc27244e406f858c6f1498400f61a606a2923d00a113fffecb4d04ff"
MATRIX = "matrix-startup-20261105"


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def digest(data):
    return hashlib.sha256(data).hexdigest()


def expected_trials():
    configs = [(w, h, fps) for w, h in [(896, 504), (1280, 720), (1504, 846), (1920, 1080), (2284, 1284)] for fps in (15, 30)]
    return [("%s-p%d-c%02d-%dx%d-%d" % (MATRIX, repetition, index + 1, w, h, fps), (w, h, fps))
            for repetition in (1, 2, 3) for index, (w, h, fps) in enumerate(configs)]


def longest_stall(values, times):
    last_change, longest = times[0], 0
    for index in range(1, len(values)):
        if values[index] > values[index - 1]:
            last_change = times[index]
        longest = max(longest, times[index] - last_change)
    return longest


def audit(root):
    checks, failures, details, performance_findings = {}, [], [], []
    original = read_json(root / "baseline/original-package.json")["original_package_evidence"]
    original_zip = Path(original["Package"])
    checks["original_package_hash"] = digest(original_zip.read_bytes()) == original["Sha256"].lower()
    with zipfile.ZipFile(original_zip) as package:
        original_winmd = digest(package.read("Rice.HoloLens.Yolo.winmd"))
        checks["original_model_native_identity"] = (digest(package.read("model.onnx")) == MODEL
                                                    and digest(package.read("Rice.HoloLens.Yolo.dll")) == NATIVE)
    status = read_json(root / (MATRIX + "-status.json"))
    expected = expected_trials()
    checks["matrix_finished"] = status["status"] == "recorded" and status["completed_trials"] == 30
    checks["all_thirty_trial_ids"] = {trial[0] for trial in expected} == {trial["run_id"] for trial in status["trials"]}
    summaries = read_json(root / "summary.json")
    summary_lookup = {run["run_id"]: run for run in summaries["runs"]}
    closing_manifest = read_json(root / "closing-control.json") if (root / "closing-control.json").exists() else {}
    restored_run = closing_manifest.get("canonical_run_id", "baseline48-restored")
    if restored_run != "baseline48-restored":
        interrupted = read_json(root / "raw/baseline48-restored/run.json")
        checks["interrupted_closing_history_preserved"] = (
            interrupted["status"] == "failed" and interrupted["completed_rounds"] == 2
            and closing_manifest.get("same_session_as_matrix") is False
            and (root / "interrupted-closing-summary.json").exists())
    sessions, script_identity, verified = set(), None, 0
    for trial_id, (width, height, fps) in expected:
        meta_path = root / "raw" / trial_id / "run.json"
        if not meta_path.exists() or read_json(meta_path)["status"] != "recorded":
            continue
        if not summary_lookup.get(trial_id, {}).get("valid"):
            continue
        try:
            meta = read_json(meta_path)
            assert meta["completed_rounds"] == 1 and meta["seconds"] == 120 and meta["warmup_seconds"] == 20
            assert meta["device"] == "HOLOLENS-I0IHKJ" and meta["ssh_identity_verified"]
            rows = [json.loads(line) for line in (meta_path.parent / "round-01.jsonl").read_text(encoding="utf-8").splitlines()]
            measured = [row for row in rows if row["measurement"]]
            assert len(measured) >= 114
            elapsed = (measured[-1]["elapsed_ms"] - measured[0]["elapsed_ms"]) / 1000
            assert elapsed >= 118
            cpu, gpu0, frame_counts, video_counts = [], [], [], []
            for row in measured:
                assert row["app"]["status"] == row["systemperf"]["status"] == 200
                state, perf = row["app"]["body"], row["systemperf"]["body"]
                camera, native = state["cameraTelemetry"], state["nativeDetector"]
                assert state["runtimeSession"] == meta["runtime_session"] and native["processId"] == meta["process_id"]
                assert state["cameraSession"] is None and state["cameraPreviewReady"]
                assert native["onDevice"] and native["deviceKind"] == 3 and native["inputSize"] == 320
                assert native["modelSha256"] == MODEL and native["source"] == "camera" and native["assetFrames"] == 0
                assert native["phase"] == "running" and native["hr"] == 0 and native["modelLoaded"]
                assert camera["key"] == "%dx%d@%d" % (width, height, fps)
                assert camera["actual"]["width"] == camera["videoWidth"] == width
                assert camera["actual"]["height"] == camera["videoHeight"] == height
                assert abs(camera["actual"]["fps"] - fps) < 1e-6
                assert camera["frameCounterMethod"] == "getVideoPlaybackQuality.totalVideoFrames"
                assert camera["decodedFrames"] is not None
                assert "Adreno" in perf["GPUData"]["AvailableAdapters"][0]["Description"]
                cpu.append(float(perf["CpuLoad"]))
                gpu0.append(float(perf["GPUData"]["AvailableAdapters"][0]["EnginesUtilization"][0]))
                frame_counts.append(native["cameraFrames"])
                video_counts.append(camera["decodedFrames"])
            assert all(b >= a for a, b in zip(frame_counts, frame_counts[1:]))
            assert all(b >= a for a, b in zip(video_counts, video_counts[1:]))
            frame_delta = frame_counts[-1] - frame_counts[0]
            assert frame_delta > 0 and video_counts[-1] > video_counts[0]
            if frame_delta < 30:
                performance_findings.append(dict(run_id=trial_id, completed_camera_inferences=frame_delta,
                                                measured_seconds=elapsed,
                                                interpretation="Low throughput retained as a timed performance result; not excluded by the separate thirty-frame model-deployment gate."))
            sample_times = [row["elapsed_ms"] / 1000 for row in measured]
            video_stall = longest_stall(video_counts, sample_times)
            model_stall = longest_stall(frame_counts, sample_times)
            if video_stall >= 10 or model_stall >= 15:
                performance_findings.append(dict(run_id=trial_id, video_counter_stall_s=video_stall,
                                                model_counter_stall_s=model_stall,
                                                interpretation="Observed performance outcome retained, not discarded. HTML presentation counter is not a sensor ingress counter."))
            assert meta["runtime_session"] not in sessions
            sessions.add(meta["runtime_session"])
            calculated = summary_lookup[trial_id]["rounds"][0]
            assert summary_lookup[trial_id]["valid"] and calculated["valid"]
            assert math.isclose(math.fsum(cpu) / len(cpu), calculated["cpu_pct"]["mean"], abs_tol=1e-8)
            assert math.isclose(math.fsum(gpu0) / len(gpu0), calculated["gpu_engines_pct"]["0"]["mean"], abs_tol=1e-8)
            assert math.isclose((frame_counts[-1] - frame_counts[0]) / elapsed, calculated["detector_fps"], abs_tol=1e-8)
            package_record = read_json(root / "packages" / trial_id / "package.json")
            package_path = Path(package_record["Package"])
            assert digest(package_path.read_bytes()) == package_record["Sha256"].lower()
            with zipfile.ZipFile(package_path) as package:
                assert digest(package.read("model.onnx")) == MODEL
                assert digest(package.read("Rice.HoloLens.Yolo.dll")) == NATIVE
                assert digest(package.read("Rice.HoloLens.Yolo.winmd")) == original_winmd
                config_bytes = package.read("config.json")
                config = json.loads(config_bytes)
                assert config["cameraDiagnostics"] is False and config["resourceTelemetry"] is True
                assert config["cameraCaptureRequest"] == dict(width=width, height=height, fps=fps)
                device_config = (root / "packages" / trial_id / "device-config.json").read_text(encoding="utf-8-sig")
                assert json.loads(device_config) == config
                script_hashes = tuple((entry["Source"], digest(package.read(entry["Deployed"]))) for entry in package_record["ScriptFiles"])
                if script_identity is None:
                    script_identity = script_hashes
                assert script_identity == script_hashes
            ready = read_json(root / "packages" / trial_id / "readiness.json")
            assert ready["runtimeSession"] == meta["runtime_session"]
            assert ready["cameraTelemetry"]["generation"] == measured[0]["app"]["body"]["cameraTelemetry"]["generation"]
            verified += 1
            details.append(dict(run_id=trial_id, verified=True, samples=len(measured), session=meta["runtime_session"],
                                max_video_counter_stall_s=video_stall, max_model_counter_stall_s=model_stall))
        except (AssertionError, KeyError, ValueError, OSError, zipfile.BadZipFile) as error:
            failures.append(dict(run_id=trial_id, error=type(error).__name__ + ": " + str(error)))
    checks["thirty_independently_verified_trials"] = verified == 30
    checks["unmodified_initial_three_rounds"] = (summary_lookup.get("baseline48-original03", {}).get("valid") is True
                                                and len(summary_lookup["baseline48-original03"]["rounds"]) == 3)
    checks["restored_original_three_rounds"] = (summary_lookup.get(restored_run, {}).get("valid") is True
                                               and len(summary_lookup[restored_run]["rounds"]) == 3)
    restoration_path = root / "restored-verification.json"
    checks["production_restoration_verified"] = False
    if restoration_path.exists():
        restoration = read_json(restoration_path)
        checks["production_restoration_verified"] = (restoration["Passed"] and restoration["Version"] == "1.0.0.48"
                                                     and restoration["CameraDiagnosticSession"] is None
                                                     and restoration["ModelSha256"] == MODEL
                                                     and restoration["RuntimeSession"] == read_json(root / "raw" / restored_run / "run.json")["runtime_session"])
        with zipfile.ZipFile(original_zip) as package:
            restored_files = restoration["VerifiedFiles"]
            checks["restored_files_match_original_appx"] = (len(restored_files) == 12 and all(
                digest(package.read(entry["Name"])) == entry["Sha256"].lower() for entry in restored_files))
    else:
        checks["restored_files_match_original_appx"] = False
    workspace = root.parent.parent
    checks["root_readme_unchanged"] = digest((workspace / "README.md").read_bytes()) == read_json(root / "baseline/original-package.json")["readme_sha256"].lower()
    result = {"schema": 1, "complete": all(checks.values()) and not failures, "checks": checks,
              "verified_matrix_trials": verified, "failed_audits": failures, "trial_details": details,
              "performance_findings": performance_findings,
              "scope": "Physical PV camera in YOLO app; all three repeats at all ten configurations; unchanged model/native binaries; original package restored and sampled again."}
    (root / "completion-audit.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    outcome = audit(args.root.resolve())
    print(json.dumps({key: value for key, value in outcome.items() if key != "trial_details"}, ensure_ascii=False, indent=2))
