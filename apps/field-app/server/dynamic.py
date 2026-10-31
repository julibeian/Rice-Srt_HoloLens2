#!/usr/bin/env python3
"""Dynamic frame inference for the Rice HoloLens application.

This module is installed inside the existing V2 model process, so the
ConvNeXtV2 weights are loaded once for both the static photo endpoint and the
dynamic frame channel. Frames are decoded and analysed in memory only; they are
never written to disk or retained after the response.

Routes:
  GET  /dynamic/health    public model/version/latency status
  GET  /dynamic/model     model manifest, channel key required
  POST /dynamic/analyze   one JPEG/PNG/WebP frame, channel key required

The endpoint returns the same class/confidence/top3 contract as /predict plus
a class-activation (CAM) attention grid and box computed from the same forward
pass. The CAM is a coarse "where the classifier looked" hint, not a lesion
detector or an accuracy claim.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import math
import os
import re
import threading
import time
import traceback
from collections import OrderedDict, deque
from io import BytesIO
from pathlib import Path

import torch
from PIL import Image, UnidentifiedImageError
from fastapi import Header, HTTPException, Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool
from torchvision import transforms

from api.cam import payload as cam_payload

DYNAMIC_VERSION = "1.0.0"
MAX_FRAME_BYTES = 1536 * 1024
MIN_SIDE = 96
MAX_SIDE = 2048
ALLOWED_SIZES = (128, 160, 192, 224)
DEFAULT_SIZE = 160
CAM_THRESHOLD = 0.7
MEAN = (0.485, 0.456, 0.406)
STD = (0.229, 0.224, 0.225)
FRAME_ID = re.compile(r"^[A-Za-z0-9._-]{1,80}$")
HEX64 = re.compile(r"^[a-f0-9]{64}$")
IMAGE_TYPES = ("image/jpeg", "image/png", "image/webp")


def _utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _manifest_path():
    return Path(os.getenv("RICE_DYNAMIC_MANIFEST",
                          "/opt/rice_disease/configs/dynamic-model.json"))


def _load_manifest():
    path = _manifest_path()
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeError):
        return {"ready": False, "path": str(path)}
    if not isinstance(value, dict):
        return {"ready": False, "path": str(path)}
    value["ready"] = True
    value["path"] = str(path)
    return value


def _classify(probability, class_names, threshold):
    confidence, class_id = torch.max(probability, dim=1)
    confidence = float(confidence.item())
    class_id = int(class_id.item())
    predicted = class_names[class_id] if class_id < len(class_names) else "Unknown"
    topk = min(3, len(class_names))
    values, indices = torch.topk(probability, k=topk, dim=1)
    top3 = [[class_names[int(indices[0, i].item())],
             round(float(values[0, i].item()), 4)] for i in range(topk)]
    if predicted == "其他":
        valid, message = False, "无效图片或非水稻叶片图片"
    elif confidence < threshold:
        valid, message = False, "无效图片或置信度过低"
    else:
        valid, message = True, "检测成功"
    return predicted, confidence, valid, message, top3


def _cam_payload(cam, threshold=CAM_THRESHOLD):
    """Normalise a HxW CAM tensor into a compact grid and a cell box."""
    if cam is None or cam.numel() == 0:
        return None
    return cam_payload(cam.detach().float().clamp_min(0).tolist(), threshold)


def _read_channel_key():
    try:
        value = Path("/var/lib/rice-hololens-app/upstream.key").read_text().strip()
        return value if len(value) >= 32 else None
    except OSError:
        return None


class _FrameCache:
    """Small bounded idempotency cache; keyed by frame id, bound to its hash."""

    def __init__(self, limit=64, ttl=180.0):
        self.lock = threading.Lock()
        self.limit = limit
        self.ttl = ttl
        self.rows = OrderedDict()

    def get(self, frame_id, sha):
        now = time.monotonic()
        with self.lock:
            row = self.rows.get(frame_id)
            if not row:
                return None
            if now - row["at"] > self.ttl:
                self.rows.pop(frame_id, None)
                return None
            if not hmac.compare_digest(row["sha"], sha):
                raise HTTPException(status_code=409, detail="帧编号已被另一张图像使用")
            self.rows.move_to_end(frame_id)
            return row["result"]

    def put(self, frame_id, sha, result):
        with self.lock:
            self.rows[frame_id] = {"sha": sha, "at": time.monotonic(),
                                   "result": result}
            self.rows.move_to_end(frame_id)
            while len(self.rows) > self.limit:
                self.rows.popitem(last=False)

    def snapshot(self):
        with self.lock:
            return {"entries": len(self.rows), "limit": self.limit,
                    "ttl_seconds": self.ttl}


class _Metrics:
    def __init__(self, limit=200):
        self.lock = threading.Lock()
        self.total = 0
        self.ok = 0
        self.failed = 0
        self.times = deque(maxlen=limit)
        self.inference = deque(maxlen=limit)
        self.inflight = 0
        self.last_error = None
        self.started_at = _utc_now()

    def begin(self):
        with self.lock:
            self.inflight += 1

    def finish(self, total_ms, inference_ms, error=None):
        with self.lock:
            self.inflight = max(0, self.inflight - 1)
            self.total += 1
            self.times.append(float(total_ms))
            if inference_ms is not None:
                self.inference.append(float(inference_ms))
            if error:
                self.failed += 1
                self.last_error = str(error)[:180]
            else:
                self.ok += 1

    @staticmethod
    def _percentile(values, fraction):
        if not values:
            return None
        ordered = sorted(values)
        index = min(len(ordered) - 1, max(0, int(round((len(ordered) - 1) * fraction))))
        return round(ordered[index], 2)

    def snapshot(self):
        with self.lock:
            times = list(self.times)
            inference = list(self.inference)
            return {
                "requests": self.total,
                "ok": self.ok,
                "failed": self.failed,
                "inflight": self.inflight,
                "latency_ms": {
                    "p50": self._percentile(times, 0.50),
                    "p95": self._percentile(times, 0.95),
                    "last": round(times[-1], 2) if times else None,
                },
                "inference_ms": {
                    "p50": self._percentile(inference, 0.50),
                    "p95": self._percentile(inference, 0.95),
                },
                "last_error": self.last_error,
                "started_at": self.started_at,
            }


class DynamicService:
    def __init__(self, context):
        self.context = context
        self.gate = threading.BoundedSemaphore(1)
        self.cache = _FrameCache()
        self.metrics = _Metrics()
        self.manifest = _load_manifest()
        self.key = _read_channel_key()
        self.manifest_loaded_at = _utc_now()

    # -- identity ---------------------------------------------------------
    def model_info(self):
        model = self.context.get("model")
        classes = list(self.context.get("class_names") or [])
        manifest = self.manifest
        return {
            "loaded": model is not None,
            "version": manifest.get("version") or "unversioned",
            "checkpoint_sha256": manifest.get("checkpoint_sha256"),
            "architecture": manifest.get("architecture") or "convnextv2_base.fcmae_ft_in1k",
            "classes": classes,
            "num_classes": len(classes),
            "input_sizes": list(manifest.get("input_sizes") or ALLOWED_SIZES),
            "default_size": int(manifest.get("default_size") or DEFAULT_SIZE),
            "threshold": float(self.context.get("CONFIDENCE_THRESHOLD") or 0.85),
            "manifest_ready": bool(manifest.get("ready")),
            "manifest_path": manifest.get("path"),
            "deployed_at": manifest.get("deployed_at"),
            "weights_stored_on": "alibaba-cloud-ecs",
        }

    def require_key(self, value):
        if not self.key or not value or not hmac.compare_digest(str(value), self.key):
            raise HTTPException(status_code=403, detail="动态识别通道鉴权失败")

    # -- health -----------------------------------------------------------
    def health(self):
        info = self.model_info()
        return {
            "status": "ok" if info["loaded"] else "model_unavailable",
            "dynamic_version": DYNAMIC_VERSION,
            "model": info,
            "cache": self.cache.snapshot(),
            "metrics": self.metrics.snapshot(),
            "frames_stored": False,
            "max_frame_bytes": MAX_FRAME_BYTES,
            "cam": True,
            "server_time": _utc_now(),
        }

    # -- inference --------------------------------------------------------
    def _decode(self, body, content_type):
        if content_type not in IMAGE_TYPES:
            raise HTTPException(status_code=415, detail="动态帧必须是 JPEG、PNG 或 WebP")
        if not body:
            raise HTTPException(status_code=422, detail="动态帧为空")
        if len(body) > MAX_FRAME_BYTES:
            raise HTTPException(status_code=413, detail="动态帧过大")
        try:
            image = Image.open(BytesIO(body))
            if getattr(image, "n_frames", 1) != 1:
                raise HTTPException(status_code=422, detail="动态帧不能是动图")
            width, height = image.size
            if width < MIN_SIDE or height < MIN_SIDE or width > MAX_SIDE or height > MAX_SIDE:
                raise HTTPException(status_code=422, detail="动态帧尺寸超出范围")
            image = image.convert("RGB")
        except HTTPException:
            raise
        except (UnidentifiedImageError, OSError, ValueError, Image.DecompressionBombError):
            raise HTTPException(status_code=422, detail="动态帧不是可读取的图像") from None
        return image

    def _infer(self, image, size):
        model = self.context.get("model")
        classes = list(self.context.get("class_names") or [])
        threshold = float(self.context.get("CONFIDENCE_THRESHOLD") or 0.85)
        if model is None or not classes:
            raise HTTPException(status_code=503, detail="模型尚未加载")
        transform = transforms.Compose([
            transforms.Resize((size, size)),
            transforms.ToTensor(),
            transforms.Normalize(MEAN, STD),
        ])
        preprocess_started = time.perf_counter()
        tensor = transform(image).unsqueeze(0)
        preprocess_ms = (time.perf_counter() - preprocess_started) * 1000.0
        captured = {}
        hook = None
        try:
            if hasattr(model, "head") and hasattr(model.head, "global_pool"):
                def _capture(module, inputs, output):
                    if inputs and isinstance(inputs[0], torch.Tensor):
                        captured["feature"] = inputs[0]
                hook = model.head.global_pool.register_forward_hook(_capture)
            inference_started = time.perf_counter()
            with torch.inference_mode():
                logits = model(tensor)
                probability = torch.nn.functional.softmax(logits, dim=1)
                predicted, confidence, valid, message, top3 = _classify(
                    probability, classes, threshold)
                class_id = int(torch.argmax(probability, dim=1).item())
            inference_ms = (time.perf_counter() - inference_started) * 1000.0
            cam_started = time.perf_counter()
            annotation = None
            feature = captured.get("feature")
            if feature is not None and hasattr(model.head, "fc"):
                weight = model.head.fc.weight[class_id].detach().float()
                cam = torch.einsum("c,chw->hw", weight, feature[0].float())
                annotation = _cam_payload(cam)
            cam_ms = (time.perf_counter() - cam_started) * 1000.0
        finally:
            if hook is not None:
                hook.remove()
        return {
            "predicted_class": predicted,
            "confidence": round(confidence, 4),
            "is_valid": valid,
            "message": message,
            "top3_predictions": top3,
            "annotation": annotation,
            "timing": {
                "preprocess_ms": round(preprocess_ms, 2),
                "inference_ms": round(inference_ms, 2),
                "cam_ms": round(cam_ms, 2),
            },
        }

    def analyze(self, body, content_type, frame_id, sha, size):
        if not FRAME_ID.fullmatch(frame_id or ""):
            raise HTTPException(status_code=422, detail="动态帧编号无效")
        if not HEX64.fullmatch(sha or ""):
            raise HTTPException(status_code=422, detail="动态帧哈希缺失")
        actual = hashlib.sha256(body).hexdigest()
        if not hmac.compare_digest(actual, sha):
            raise HTTPException(status_code=422, detail="动态帧哈希不匹配")
        hit = self.cache.get(frame_id, sha)
        if hit is not None:
            value = dict(hit)
            value["cache"] = "hit"
            return value
        if not self.gate.acquire(blocking=False):
            raise HTTPException(status_code=429, detail="动态识别正在处理上一帧",
                                headers={"Retry-After": "1"})
        started = time.perf_counter()
        self.metrics.begin()
        error = None
        inference_ms = None
        try:
            # Second check after acquiring the single-flight gate: a concurrent
            # retry may have completed while this request waited.
            hit = self.cache.get(frame_id, sha)
            if hit is not None:
                value = dict(hit)
                value["cache"] = "hit"
                return value
            image = self._decode(body, content_type)
            result = self._infer(image, size)
            total_ms = (time.perf_counter() - started) * 1000.0
            value = dict(result)
            value.update({
                "frame_id": frame_id,
                "image_sha256": actual,
                "model": {
                    "version": self.manifest.get("version") or "unversioned",
                    "checkpoint_sha256": self.manifest.get("checkpoint_sha256"),
                    "architecture": self.manifest.get("architecture") or "convnextv2_base.fcmae_ft_in1k",
                    "input_size": size,
                },
                "timing": dict(result["timing"], total_ms=round(total_ms, 2)),
                "cache": "miss",
                "frames_stored": False,
                "analyzed_at": _utc_now(),
            })
            inference_ms = result.get("timing", {}).get("inference_ms")
            self.cache.put(frame_id, sha, value)
            return value
        except HTTPException as exc:
            error = f"{exc.status_code}: {exc.detail}"
            raise
        except Exception:
            error = "internal"
            traceback.print_exc()
            raise HTTPException(status_code=500, detail="动态识别内部错误") from None
        finally:
            self.metrics.finish((time.perf_counter() - started) * 1000.0,
                                inference_ms, error)
            self.gate.release()


def install_dynamic(app, context):
    """Mount dynamic routes into the existing FastAPI application."""
    service = DynamicService(context)

    @app.get("/dynamic/health")
    def dynamic_health():
        return JSONResponse(content=service.health())

    @app.get("/dynamic/model")
    def dynamic_model(x_rice_channel_key: str = Header(default="")):
        service.require_key(x_rice_channel_key)
        return JSONResponse(content=service.model_info())

    @app.post("/dynamic/analyze")
    async def dynamic_analyze(request: Request,
                              x_rice_channel_key: str = Header(default=""),
                              x_frame_id: str = Header(default=""),
                              x_image_sha256: str = Header(default=""),
                              x_dynamic_size: str = Header(default="")):
        service.require_key(x_rice_channel_key)
        declared = request.headers.get("content-length")
        try:
            if declared is not None and int(declared) > MAX_FRAME_BYTES:
                raise HTTPException(status_code=413, detail="动态帧过大")
        except ValueError:
            raise HTTPException(status_code=400, detail="动态帧长度无效") from None
        body = await request.body()
        size = service.model_info()["default_size"]
        if x_dynamic_size:
            try:
                requested = int(x_dynamic_size)
            except ValueError:
                raise HTTPException(status_code=422, detail="动态输入尺寸无效") from None
            if requested not in (service.model_info()["input_sizes"] or ALLOWED_SIZES):
                raise HTTPException(status_code=422, detail="不支持的动态输入尺寸")
            size = requested
        content_type = (request.headers.get("content-type") or "").split(";")[0].strip().lower()
        result = await run_in_threadpool(
            service.analyze, body, content_type, x_frame_id,
            x_image_sha256.lower(), size)
        return JSONResponse(content=result)

    return service
