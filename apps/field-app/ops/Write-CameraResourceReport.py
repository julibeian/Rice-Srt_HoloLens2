"""Write the human-readable report from audited, preserved camera measurements."""
import argparse
import json
import statistics
from pathlib import Path


def read(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def main(root):
    audit = read(root / "completion-audit.json")
    if not audit["complete"]:
        raise RuntimeError("The physical-camera data and restoration audit is incomplete")
    configs = read(root / "configuration-summary.json")
    runs = {run["run_id"]: run for run in read(root / "summary.json")["runs"]}
    closing = read(root / "closing-control.json")
    interrupted = read(root / "interrupted-closing-summary.json")
    rounds = read(root / "round-summary.json")
    verification = read(root / "restored-verification.json")
    checks = read(root / "checks/results.json")
    matrix = read(root / "matrix-startup-20261105-status.json")
    assert len(configs) == 10 and all(value["completed_repeats"] == 3 for value in configs)

    def control_stats(values):
        return "CPU %.2f%%、GPU0 %.2f%%、检测 %.3f 次/秒" % (
            statistics.mean(value["cpu_pct"]["mean"] for value in values),
            statistics.mean(value["gpu_engines_pct"]["0"]["mean"] for value in values),
            statistics.mean(value["detector_fps"] for value in values))

    table = "\n".join("| %s | %.2f | %.2f | %.2f | %.3f | %.3f–%.3f |" % (
        value["camera_key"].replace("x", "×").replace("@", " / ") + " fps",
        value["cpu_mean_pct"], value["gpu0_mean_pct"], value["video_displayed_fps"],
        value["detector_fps"], value["detector_fps_repeat_min"], value["detector_fps_repeat_max"])
        for value in configs)
    default_trials = sorted((value for value in rounds if value["camera_key"] == "896x504@30"), key=lambda value: value["run_id"])
    drift = " → ".join("%.3f" % value["detector_fps"] for value in default_trials)
    battery_min = min(value["battery_min_pct"] for value in configs)
    battery_max = max(value["battery_max_pct"] for value in configs)
    text = f"""# YOLO 真实相机参数与眼镜资源采样报告

主测试日期：2026-11-05，Asia/Shanghai。收尾补测与核验日期：2026-11-06。**30轮主测试、三轮独立收尾补测及原包文件核验均已完成。**

测试对象是稻视界 YOLO 使用 HoloLens 自身 PV 相机连续取景时的整机负载。相机采集和 WinML GPU 推理都在眼镜内；电脑通过原身份 USB 通道下发包配置、读取统计。30轮的相机诊断素材入口均关闭，原始记录中 `source=camera`、`assetFrames=0`。原模型输入固定320，原生 DLL 和模型逐包核对为原字节；没有用电脑播放图片代替相机输入。

**方法。** 五个相机尺寸各测15/30 fps，每档三轮。每轮重新建立应用与真实相机会话，预热20秒后定时采样120秒；CPU、全部GPU引擎和应用状态按1 Hz读取，热/供电状态约每10秒读取。三轮顺序为升档、降档、升档。主矩阵从 {matrix['started_at']} 到 {matrix['finished_at']}，共3600个测量点；每轮首尾样本约间隔119秒。测量中未额外打开全息视频串流；21:32做过一次已登记的只读本应用进程核对，没有删除对应样本。

**三轮结果。** 表中为三轮均值，最后一列是每轮检测吞吐的最小/最大值。CPU为眼镜整机 `CpuLoad`，GPU列仅为第0引擎；其他引擎保留在原始JSONL和CSV中，未相加成“总GPU”。

| 相机配置（驱动读回） | CPU % | GPU0 % | HTML显示计数 fps | 完成检测/秒 | 三轮检测范围 |
| --- | ---: | ---: | ---: | ---: | ---: |
{table}

提高的是PV相机采集/预览尺寸，模型张量仍为320×320；原程序送入预处理的像素图还有1920×1080上限，具体送入尺寸见每轮CSV。因此这些数据不能称为不同模型输入大小的测试。

**计数口径。** 相机配置是WinRT属性读回结果。HTML显示计数率取 `totalVideoFrames - droppedVideoFrames` 的差分，不是传感器全部采集帧的直接计数；该计数定义见[W3C Media Playback Quality](https://w3c.github.io/media-playback-quality/)。完成检测率取原生组件完成推理和NMS之后的 `cameraFrames` 增量。时延为唯一观测结果的样本统计，不是全帧日志；`captureToResultMs`的起点是原生提交，不是曝光起点。整机统计接口口径见[微软设备门户API](https://learn.microsoft.com/en-us/windows/mixed-reality/device-portal-api-reference#performance-data)。

**持续运行与限制。** 同为896×504 / 30 fps，三轮检测吞吐依次为 {drift} 次/秒。测试期间接口电量比读数跨越 {battery_min:.1f}%–{battery_max:.1f}%，系统内存与运行时长也变化；未锁定CPU/GPU时钟、曝光或不同VideoProfile的内部策略。因此不能把所有降速都归因于像素，也不能只凭整机CPU未满就认定没有线程或同步瓶颈。采样时热阶段均为0不等于已测得实际温度或排除了所有限频。

2284×1284 / 15 fps第二轮有一次约11.01秒的HTML计数停顿，期间原生相机结果从73增至80、像素采样摘要有8个不同值。它被原样保留，不能据此断言相机停拍，也没有在测量中开串流来确认人眼画面是否冻结。详情见[停顿片段](preview-stall-p2-c09.json)。低吞吐和呈现计数停顿是性能结果，未为取得好结果重跑或删样本。

**原包前后对照与中断。**

- 11月5日最初未修改原包的三轮：{control_stats(runs['baseline48-original03']['rounds'])}。
- 当晚还原后的两轮完整记录：{control_stats(interrupted['rounds'])}。第三轮仅有104个有效测量点，21:52:52接口报告网络不可达，整组保持失败状态；原始数据未覆盖，见[中断收尾记录](interrupted-closing-summary.json)。
- 11月6日重连、重新启动后的三轮：{control_stats(runs[closing['canonical_run_id']]['rounds'])}。它是不同日期、会话和供电条件下的独立收尾对照，不冒充当晚连续会话的第三轮。各轮供电和电量原值均保存。

**恢复与核验。** 当前已恢复原1.0.0.48包，诊断入口关闭。新会话 `{verification['RuntimeSession']}` 实际推理，核验时已有{verification['CameraFrames']}个相机新帧。设备回读12个文件均匹配原始APPX，包括原模型、DLL、WinMD、配置和五个脚本。根README哈希未变；这是资源测试，不是病害准确率验收。数据独立复算及逐包身份核验见[完成审计](completion-audit.json)。Node {checks['node']['passed']}项、Python {checks['python']['passed']}项、五个PowerShell文件解析和Git差异检查通过，见[检查记录](checks/results.json)。

**交付与复算。**

- [完整配置汇总CSV](configuration-summary.csv)、[逐轮CSV](round-summary.csv)、[逐秒CSV](time-series.csv)、[原始JSONL哈希清单](raw-manifest.json)。
- [配置对照图](configuration-comparison.png)、[11月5日时间曲线](resource-timeline.png)、[11月6日收尾曲线](resource-timeline-20261106.png)。
- [冻结实验计划](matrix-startup-20261105-plan.json)、[实验源码快照](source/application-as-run.json)、[收尾与中断关系](closing-control.json)、[恢复文件核验](restored-verification.json)。

在仓库根目录复算现有数据（不会连接或改变眼镜）：

```powershell
py -3.14 apps/field-app/ops/Analyze-YoloResources.py reports/20261105-yolo-camera-resources --plot
py -3.14 apps/field-app/ops/Audit-CameraResourceMatrix.py reports/20261105-yolo-camera-resources
py -3.14 apps/field-app/ops/Write-CameraResourceReport.py reports/20261105-yolo-camera-resources
```

原始JSONL、包、权重、私人室内画面保留本机。失效的在线参数命令方案已归档，30轮主矩阵全部使用启动时的真实相机参数；当前代码移除了该未使用命令分支。后续复做必须用新RunId，不能覆盖本次记录。
"""
    (root / "采样报告.md").write_text(text, encoding="utf-8")
    print("Report written with all ten configurations and the interrupted/resumed closing controls.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    main(parser.parse_args().root.resolve())
