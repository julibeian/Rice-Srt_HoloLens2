"""Recompute resource statistics from preserved Device Portal JSONL observations."""
import argparse
import csv
import hashlib
import json
import math
import re
import statistics
from pathlib import Path

MODEL_SHA = "e6b6d2f6baaae3b7970f1a4e425f2c2347a90fe6aab34c3da0aed738fcf1b048"


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def distribution(values):
    values = sorted(float(x) for x in values)
    if not values or not all(math.isfinite(x) for x in values):
        raise ValueError("Missing or non-finite observations")
    return {"n": len(values), "mean": statistics.mean(values), "min": values[0],
            "max": values[-1], "p50": values[math.ceil(len(values) * .5) - 1],
            "p95": values[math.ceil(len(values) * .95) - 1]}


def summarize_round(meta, rows):
    measured = [row for row in rows if row["measurement"]]
    if len(measured) < math.floor(meta["seconds"] / meta["interval_seconds"] * .95):
        raise ValueError("Insufficient measured samples")
    duration = (measured[-1]["elapsed_ms"] - measured[0]["elapsed_ms"]) / 1000
    if duration < meta["seconds"] - 2 * meta["interval_seconds"]:
        raise ValueError("Measurement interval is shorter than the declared round")
    cpu, gpu, ram, gpu_memory, frame_results, flattened = [], [], [], [], {}, []
    generations, thermal, seen_frames, battery_percent, power_states, charging_states = set(), [], [], [], set(), set()
    for row in measured:
        if row["app"].get("status") != 200 or row["systemperf"].get("status") != 200:
            raise ValueError("Failed required endpoint")
        state, perf = row["app"]["body"], row["systemperf"]["body"]
        native = state["nativeDetector"]
        if (state["version"] != meta["expected_version"]
                or state["runtimeSession"] != meta["runtime_session"]
                or native["processId"] != meta["process_id"]
                or native["modelSha256"] != MODEL_SHA or native["inputSize"] != 320
                or not native["onDevice"] or native["phase"] != "running"
                or native["source"] != "camera" or native["hr"] != 0
                or not state["cameraPreviewReady"]):
            raise ValueError("Wrong session/model or unhealthy camera inference")
        camera = state.get("cameraTelemetry")
        if meta.get("expected_camera_key"):
            if (not camera or camera["key"] != meta["expected_camera_key"]
                    or camera["videoWidth"] != camera["actual"]["width"]
                    or camera["videoHeight"] != camera["actual"]["height"]):
                raise ValueError("Actual camera properties do not match the experiment")
            expected = re.fullmatch(r"(\d+)x(\d+)@([\d.]+)", meta["expected_camera_key"])
            if (not expected or camera["actual"]["width"] != int(expected[1])
                    or camera["actual"]["height"] != int(expected[2])
                    or abs(camera["actual"]["fps"] - float(expected[3])) > .001):
                raise ValueError("Driver readback differs from the requested rate or dimensions")
            generations.add(camera["generation"])
        load = float(perf["CpuLoad"])
        engines = [float(x) for x in perf["GPUData"]["AvailableAdapters"][0]["EnginesUtilization"]]
        if not engines or not all(math.isfinite(x) and 0 <= x <= 100 for x in [load] + engines):
            raise ValueError("Invalid CPU/GPU percent")
        cpu.append(load)
        gpu.append(engines)
        ram.append((perf["TotalPages"] - perf["AvailablePages"]) * perf["PageSize"] / 2**20)
        gpu_memory.append(perf["GPUData"]["AvailableAdapters"][0]["SystemMemoryUsed"] / 2**20)
        frame_results[native["cameraFrames"]] = native
        seen_frames.append(native["cameraFrames"])
        health = row.get("health") or {}
        if health.get("power", {}).get("body", {}).get("LowPowerState"):
            raise ValueError("Device entered low power")
        stage = health.get("thermal", {}).get("body", {}).get("CurrentStage")
        if stage is not None:
            thermal.append(stage)
        battery = health.get("battery", {}).get("body") or {}
        charge = None
        if battery.get("MaximumCapacity", 0) > 0:
            charge = 100 * battery["RemainingCapacity"] / battery["MaximumCapacity"]
            battery_percent.append(charge)
        if "AcOnline" in battery:
            power_states.add(battery["AcOnline"])
        if "Charging" in battery:
            charging_states.add(battery["Charging"])
        flat = {"at": row["at"], "elapsed_s": row["elapsed_ms"] / 1000,
                "cpu_pct": load, "ram_used_mib": ram[-1], "gpu_shared_mib": gpu_memory[-1],
                "detector_frames": native["cameraFrames"], "frame_time_ms": native["frameTime"],
                "inference_ms": native["inferenceMs"], "preprocess_ms": native["preprocessMs"],
                "submit_to_result_ms": native["captureToResultMs"], "thermal_stage": stage,
                "battery_capacity_ratio_pct": charge,
                "camera_key": camera.get("key") if camera else "original_uninstrumented",
                "video_total_frames": camera.get("decodedFrames") if camera else None,
                "dropped_frames": camera.get("droppedFrames") if camera else None,
                "js_pixels_ms": camera.get("lastReadPixelsMs") if camera else None,
                "js_submit_ms": camera.get("lastSubmitMs") if camera else None,
                "request_duration_ms": row["completed_elapsed_ms"] - row["elapsed_ms"],
                "overrun_ms": row["overrun_ms"]}
        flat.update({"gpu_engine_%d_pct" % index: value for index, value in enumerate(engines)})
        flattened.append(flat)
    if any(b < a for a, b in zip(seen_frames, seen_frames[1:])):
        raise ValueError("Detector counter reset within the measured round")
    delta = seen_frames[-1] - seen_frames[0]
    if delta <= 0:
        raise ValueError("No completed new camera inference in the measured interval")
    if len(generations) > 1:
        raise ValueError("Camera restarted within the measured round")
    native_results = list(frame_results.values())
    first_camera, last_camera = measured[0]["app"]["body"].get("cameraTelemetry"), measured[-1]["app"]["body"].get("cameraTelemetry")
    preview = {"available": False, "reason": "original build has no video counter telemetry"}
    if first_camera and last_camera:
        preview = {"available": False, "method": last_camera["frameCounterMethod"],
                   "actual": last_camera["actual"], "video_width": last_camera["videoWidth"],
                   "video_height": last_camera["videoHeight"],
                   "profile_id": (last_camera.get("selected") or {}).get("profileId")}
        if (first_camera.get("decodedFrames") is not None and last_camera.get("decodedFrames") is not None
                and last_camera["decodedFrames"] > first_camera["decodedFrames"]):
            total_delta = last_camera["decodedFrames"] - first_camera["decodedFrames"]
            dropped_delta = last_camera["droppedFrames"] - first_camera["droppedFrames"]
            preview.update({"available": True,
                            "counter_delta": total_delta,
                            "observed_total_fps": total_delta / duration,
                            "observed_displayed_fps": (total_delta - dropped_delta) / duration,
                            "dropped_delta": dropped_delta,
                            "counter_scope": "HTML video displayed plus dropped frames; not a direct sensor-frame counter. Raw decodedFrames is a historical field name for totalVideoFrames."})
        else:
            preview["reason"] = "video frame counter unavailable or not advancing"
    output = {"valid": True, "sample_count": len(measured), "observed_seconds": duration,
              "cpu_pct": distribution(cpu),
              "gpu_engines_pct": {str(index): distribution([value[index] for value in gpu])
                                  for index in range(len(gpu[0]))},
              "ram_used_mib": distribution(ram), "gpu_shared_mib": distribution(gpu_memory),
              "camera_inference_delta": delta, "detector_fps": delta / duration,
              "fewer_than_30_inferences": delta < 30,
              "observed_result_count": len(native_results),
              "inference_ms_observed_results": distribution([r["inferenceMs"] for r in native_results]),
              "preprocess_ms_observed_results": distribution([r["preprocessMs"] for r in native_results]),
              "submit_to_result_ms_observed_results": distribution([r["captureToResultMs"] for r in native_results]),
              "thermal_stages": sorted(set(thermal)), "preview": preview,
              "battery_capacity_ratio_pct": distribution(battery_percent) if battery_percent else None,
              "external_power_states": sorted(power_states), "charging_states": sorted(charging_states),
              "source_sizes": sorted({(r["sourceWidth"], r["sourceHeight"]) for r in native_results}),
              "sample_request_ms": distribution([row["request_duration_ms"] for row in flattened]),
              "caveat": "Inference latency statistics use unique observed results, not an all-frame trace. CPU is complete-device load. GPU engines are separate, never summed. Low inference counts are retained performance outcomes of a timed resource trial, not a model deployment gate."}
    return output, flattened


def analyze(root):
    runs, csv_rows, manifest = [], [], []
    for run_dir in sorted((root / "raw").iterdir()):
        if not (run_dir / "run.json").exists():
            continue
        meta = read_json(run_dir / "run.json")
        record = {"run_id": meta["run_id"], "status": meta["status"],
                  "expected_camera_key": meta.get("expected_camera_key"), "rounds": []}
        for path in sorted(run_dir.glob("round-*.jsonl")):
            if meta["status"] != "recorded":
                continue
            raw_bytes = path.read_bytes()
            manifest.append({"path": path.relative_to(root).as_posix(), "bytes": len(raw_bytes),
                             "sha256": hashlib.sha256(raw_bytes).hexdigest()})
            try:
                rows = [json.loads(line) for line in raw_bytes.decode("utf-8-sig").splitlines()]
                summary, flat = summarize_round(meta, rows)
                summary["file"] = path.relative_to(root).as_posix()
                record["rounds"].append(summary)
                csv_rows.extend(dict(run_id=meta["run_id"], round=path.stem, **row) for row in flat)
            except (ValueError, KeyError, TypeError, IndexError) as error:
                record["rounds"].append({"file": path.relative_to(root).as_posix(), "valid": False, "error": str(error)})
        record["valid"] = (meta["status"] == "recorded" and len(record["rounds"]) == meta["rounds"]
                           and all(r["valid"] for r in record["rounds"]))
        runs.append(record)
    (root / "summary.json").write_text(json.dumps({"schema": 1, "runs": runs}, ensure_ascii=False, indent=2), encoding="utf-8")
    (root / "raw-manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    if csv_rows:
        names = list(dict.fromkeys(key for row in csv_rows for key in row))
        with (root / "time-series.csv").open("w", encoding="utf-8-sig", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=names)
            writer.writeheader()
            writer.writerows(csv_rows)
    return runs, csv_rows


def comparison_tables(root, runs):
    """Keep the true-camera matrix separate from unmodified/diagnostic controls."""
    rounds, groups = [], {}
    for run in runs:
        if not run["valid"] or not run["run_id"].startswith("matrix-startup-20261105-"):
            continue
        key = run["expected_camera_key"]
        for result in run["rounds"]:
            preview = result["preview"]
            row = {"run_id": run["run_id"], "camera_key": key,
                   "cpu_mean_pct": result["cpu_pct"]["mean"], "cpu_p95_pct": result["cpu_pct"]["p95"],
                   "gpu0_mean_pct": result["gpu_engines_pct"]["0"]["mean"],
                   "gpu0_p95_pct": result["gpu_engines_pct"]["0"]["p95"],
                   "video_displayed_fps": preview.get("observed_displayed_fps"),
                   "video_total_fps": preview.get("observed_total_fps"),
                   "driver_fps": preview.get("actual", {}).get("fps"),
                   "detector_fps": result["detector_fps"],
                   "inference_mean_ms_sampled": result["inference_ms_observed_results"]["mean"],
                   "preprocess_mean_ms_sampled": result["preprocess_ms_observed_results"]["mean"],
                   "ram_mean_mib": result["ram_used_mib"]["mean"],
                   "thermal_stages": ",".join(str(x) for x in result["thermal_stages"]),
                   "battery_min_pct": (result.get("battery_capacity_ratio_pct") or {}).get("min"),
                   "battery_max_pct": (result.get("battery_capacity_ratio_pct") or {}).get("max"),
                   "external_power_states": ",".join(str(x) for x in result.get("external_power_states", [])),
                   "submitted_sizes": ",".join("%dx%d" % tuple(x) for x in result["source_sizes"]),
                   "camera_profile_id": preview.get("profile_id"), "measured_seconds": result["observed_seconds"],
                   "sample_count": result["sample_count"]}
            rounds.append(row)
            groups.setdefault(key, []).append(row)
    summaries = []
    for key, values in groups.items():
        row = {"camera_key": key, "completed_repeats": len(values),
               "all_three_repeats": len(values) == 3,
               "requested_fps": values[0]["driver_fps"],
               "measured_seconds": sum(value["measured_seconds"] for value in values),
               "sample_count": sum(value["sample_count"] for value in values)}
        battery_low = [value["battery_min_pct"] for value in values if value["battery_min_pct"] is not None]
        battery_high = [value["battery_max_pct"] for value in values if value["battery_max_pct"] is not None]
        row["battery_min_pct"] = min(battery_low) if battery_low else None
        row["battery_max_pct"] = max(battery_high) if battery_high else None
        for name in ("cpu_mean_pct", "gpu0_mean_pct", "video_displayed_fps", "detector_fps",
                     "inference_mean_ms_sampled", "preprocess_mean_ms_sampled", "ram_mean_mib"):
            observations = [value[name] for value in values if value[name] is not None]
            row[name] = statistics.mean(observations) if observations else None
            row[name + "_repeat_min"] = min(observations) if observations else None
            row[name + "_repeat_max"] = max(observations) if observations else None
        summaries.append(row)
    summaries.sort(key=lambda value: (int(value["camera_key"].split("x")[0]), value["requested_fps"]))
    for name, data in (("round-summary", rounds), ("configuration-summary", summaries)):
        (root / (name + ".json")).write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        if data:
            with (root / (name + ".csv")).open("w", encoding="utf-8-sig", newline="") as stream:
                writer = csv.DictWriter(stream, fieldnames=list(data[0]))
                writer.writeheader()
                writer.writerows(data)
    return summaries


def plot_results(root, csv_rows):
    from datetime import datetime
    from zoneinfo import ZoneInfo
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.dates as mdates
    import matplotlib.pyplot as plt
    import numpy as np
    days = sorted({row["at"][:10] for row in csv_rows})
    for day_index, day in enumerate(days):
        grouped = {}
        for row in csv_rows:
            if row["at"].startswith(day):
                grouped.setdefault(row["run_id"], []).append(row)
        fig, axes = plt.subplots(4, 1, figsize=(14, 11), sharex=True, layout="constrained")
        colors, shown = {}, set()
        for run_id, rows in grouped.items():
            key = rows[0]["camera_key"] if run_id.startswith("matrix-startup-") else ("Original v48" if run_id.startswith("baseline48-") else "Diagnostic reference")
            if key not in colors:
                colors[key] = plt.get_cmap("tab20")(len(colors) / 20)
            label = key if key not in shown else None
            shown.add(key)
            times = [datetime.fromisoformat(row["at"]) for row in rows]
            axes[0].plot(times, [r["cpu_pct"] for r in rows], linewidth=.65, color=colors[key], label=label)
            axes[1].plot(times, [r["gpu_engine_0_pct"] for r in rows], linewidth=.65, color=colors[key])
            axes[2].plot(times, [r["ram_used_mib"] for r in rows], linewidth=.65, color=colors[key])
            axes[3].plot(times, [r["battery_capacity_ratio_pct"] for r in rows], linewidth=.65, color=colors[key])
        axes[0].set_ylabel("Device CPU (%)")
        axes[1].set_ylabel("GPU engine 0 (%)")
        axes[2].set_ylabel("Device RAM used (MiB)")
        axes[3].set_ylabel("Battery ratio (%)")
        axes[3].set_xlabel(day + " local time (Asia/Shanghai); warmup/configuration gaps omitted from traces")
        axes[3].xaxis.set_major_formatter(mdates.DateFormatter("%H:%M", tz=ZoneInfo("Asia/Shanghai")))
        for axis in (axes[0], axes[1], axes[3]):
            axis.set_ylim(0, 105)
        axes[2].set_ylim(0, 4096)
        for axis in axes:
            axis.grid(alpha=.25)
        axes[0].legend(fontsize=7, ncol=4)
        name = "resource-timeline.png" if day_index == 0 else "resource-timeline-" + day.replace("-", "") + ".png"
        fig.savefig(root / name, dpi=180)
        plt.close(fig)
    summaries = read_json(root / "configuration-summary.json")
    if not summaries:
        return
    sizes = ["896x504", "1280x720", "1504x846", "1920x1080", "2284x1284"]
    lookup = {item["camera_key"]: item for item in summaries}
    fig, axes = plt.subplots(2, 2, figsize=(13, 9), layout="constrained")
    metrics = [("cpu_mean_pct", "Device CPU (%)", (0, 45)),
               ("gpu0_mean_pct", "GPU engine 0 (%)", (0, 105)),
               ("video_displayed_fps", "HTML video displayed frames / second", (0, 35)),
               ("detector_fps", "Completed camera inferences / second", (0, 1.7))]
    for axis, (metric, title, limits) in zip(axes.flat, metrics):
        for offset, rate, color in ((-.18, 15, "#167c80"), (.18, 30, "#d27d2d")):
            entries = [lookup.get(size + "@" + str(rate)) for size in sizes]
            means = np.array([entry[metric] if entry and entry[metric] is not None else np.nan for entry in entries])
            low = np.array([entry[metric + "_repeat_min"] if entry and entry[metric] is not None else np.nan for entry in entries])
            high = np.array([entry[metric + "_repeat_max"] if entry and entry[metric] is not None else np.nan for entry in entries])
            positions = np.arange(len(sizes)) + offset
            axis.bar(positions, means, width=.34, color=color, label=str(rate) + " fps requested",
                     yerr=np.vstack([means - low, high - means]), capsize=3)
            for position, value, upper in zip(positions, means, high):
                if math.isfinite(value):
                    axis.text(position, upper + (limits[1] * .018), ("%.2f" if metric == "detector_fps" else "%.1f") % value,
                              ha="center", va="bottom", fontsize=8)
        axis.set_title(title)
        axis.set_xticks(np.arange(len(sizes)), sizes, rotation=20)
        axis.set_ylim(*limits)
        axis.grid(axis="y", alpha=.2)
        axis.set_axisbelow(True)
    axes[0, 0].legend(fontsize=9)
    completed = sum(item["completed_repeats"] for item in summaries)
    fig.suptitle("Physical PV camera + on-device YOLO320 | %d / 30 matrix trials recorded\nBars: mean of trial means; error bars: min/max across repetitions" % completed, fontsize=12)
    fig.savefig(root / "configuration-comparison.png", dpi=180)
    plt.close(fig)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--plot", action="store_true")
    args = parser.parse_args()
    records, flat_rows = analyze(args.root.resolve())
    comparison_tables(args.root.resolve(), records)
    if args.plot:
        plot_results(args.root.resolve(), flat_rows)
    for record in records:
        print(json.dumps({"run_id": record["run_id"], "status": record["status"], "valid": record["valid"],
                          "rounds": [{"valid": r["valid"], "error": r.get("error"),
                                      "cpu": r.get("cpu_pct", {}).get("mean"),
                                      "gpu0": r.get("gpu_engines_pct", {}).get("0", {}).get("mean"),
                                      "detector_fps": r.get("detector_fps"), "preview": r.get("preview")}
                                     for r in record["rounds"]]}, ensure_ascii=False))
