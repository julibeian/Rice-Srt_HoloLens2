#!/usr/bin/env python3
"""Isolated HoloLens capture gateway. Python 3.10+, standard library only.

It never loads or changes a model. Authenticated new captures are sent to the
existing loopback /predict endpoint, and only the latest image is retained.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import hmac
import http.client
import json
import math
import mimetypes
import os
import re
import secrets
import threading
import time
import uuid
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit


VERSION = "1.0.0"
PREFIX = "/hololens/"
MAX_UPLOAD_BYTES = 8 * 1024 * 1024
MAX_EVENT_BYTES = 16 * 1024
IDENTIFIER = re.compile(r"^[A-Za-z0-9._:-]{1,64}$")


def utc_now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, separators=(",", ":"))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def issue_session(path, run_id=None, ttl=86400, replace=False):
    path = Path(path)
    if path.exists() and not replace:
        return json.loads(path.read_text(encoding="utf-8"))
    run_id = run_id or "hl-" + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d") + "-" + secrets.token_hex(4)
    if not IDENTIFIER.fullmatch(run_id):
        raise ValueError("Invalid run identifier")
    if ttl < 60 or ttl > 7 * 86400:
        raise ValueError("Session lifetime must be between 60 seconds and 7 days")
    session = {"run_id": run_id, "token": secrets.token_urlsafe(32),
               "created_at": utc_now(), "expires_epoch": time.time() + ttl}
    atomic_json(path, session)
    return session


class CaptureError(Exception):
    def __init__(self, status, code, message):
        self.status, self.code, self.message = status, code, message
        super().__init__(message)


def parse_capture(body, content_type):
    if not content_type.lower().startswith("multipart/form-data") or "boundary=" not in content_type:
        raise CaptureError(415, "multipart_required", "Use multipart/form-data with one file field")
    if "\r" in content_type or "\n" in content_type:
        raise CaptureError(400, "invalid_content_type", "Invalid content type")
    message = BytesParser(policy=policy.default).parsebytes(
        ("Content-Type: " + content_type + "\r\nMIME-Version: 1.0\r\n\r\n").encode("ascii") + body)
    if not message.is_multipart() or message.defects:
        raise CaptureError(422, "invalid_multipart", "Invalid multipart body")
    parts = list(message.iter_parts())
    if len(parts) > 8:
        raise CaptureError(422, "too_many_parts", "Too many form fields")
    files = [part for part in parts if part.get_param("name", header="content-disposition") == "file"]
    if len(files) != 1:
        raise CaptureError(422, "single_file_required", "Exactly one file field is required")
    data = files[0].get_payload(decode=True)
    if not data:
        raise CaptureError(422, "empty_image", "The captured image is empty")
    if data.startswith(b"\xff\xd8\xff"):
        image_type, extension = "image/jpeg", ".jpg"
    elif data.startswith(b"\x89PNG\r\n\x1a\n"):
        image_type, extension = "image/png", ".png"
    elif data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        image_type, extension = "image/webp", ".webp"
    else:
        raise CaptureError(415, "unsupported_image", "Capture a JPEG, PNG, or WebP image")
    return data, image_type, extension


class CaptureState:
    def __init__(self, session, data_dir, web_root, upstream_url="http://127.0.0.1:8002", upstream_timeout=35):
        if not IDENTIFIER.fullmatch(session["run_id"]) or len(session["token"]) < 32:
            raise ValueError("Invalid capture session")
        target = urlsplit(upstream_url)
        if target.scheme != "http" or target.hostname not in ("127.0.0.1", "localhost") or target.path not in ("", "/"):
            raise ValueError("Upstream must be a loopback HTTP origin")
        self.session = session
        self.data_dir = Path(data_dir)
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.web_root = Path(web_root).resolve()
        self.upstream_host, self.upstream_port = target.hostname, target.port or 80
        self.upstream_timeout = upstream_timeout
        self.lock = threading.RLock()
        self.inference_slot = threading.BoundedSemaphore(1)
        self.started_at = utc_now()
        self.evidence_path = self.data_dir / "evidence.json"
        self.image_path = self.data_dir / "latest-capture.bin"
        self.evidence = {"run_id": session["run_id"], "created_at": session["created_at"],
                         "events": [], "latest_prediction": None}
        if self.evidence_path.is_file():
            previous = json.loads(self.evidence_path.read_text(encoding="utf-8"))
            if previous.get("run_id") == session["run_id"]:
                self.evidence = previous

    def redact(self, value):
        if isinstance(value, str):
            return value.replace(self.session["token"], "[redacted]")[:512]
        return value

    def save(self):
        atomic_json(self.evidence_path, self.evidence)

    def record_event(self, event, request_id=None, details=None, user_agent=""):
        if not isinstance(event, str) or not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", event):
            raise CaptureError(422, "invalid_event", "Invalid event name")
        if request_id is not None and (not isinstance(request_id, str) or not IDENTIFIER.fullmatch(request_id)):
            raise CaptureError(422, "invalid_request_id", "Invalid request identifier")
        if details is not None and not isinstance(details, dict):
            raise CaptureError(422, "invalid_details", "Event details must be an object")
        cleaned = {}
        for key, value in (details or {}).items():
            if len(cleaned) >= 32:
                break
            if (isinstance(key, str) and re.fullmatch(r"[a-zA-Z][a-zA-Z0-9_]{0,47}", key)
                    and key.lower() not in ("token", "authorization", "password", "image", "photo", "url")
                    and (value is None or isinstance(value, (str, int, float, bool)))
                    and not (isinstance(value, float) and not math.isfinite(value))):
                cleaned[key] = self.redact(value)
        entry = {"sequence": 0, "event": event, "run_id": self.session["run_id"],
                 "request_id": request_id, "received_at": utc_now(), "details": cleaned,
                 "user_agent": self.redact(user_agent)}
        with self.lock:
            entries = self.evidence["events"]
            entry["sequence"] = entries[-1]["sequence"] + 1 if entries else 1
            self.evidence["events"] = (entries + [entry])[-300:]
            self.save()
        return entry["sequence"]

    def forward(self, body, content_type, request_id):
        connection = http.client.HTTPConnection(self.upstream_host, self.upstream_port, timeout=self.upstream_timeout)
        try:
            connection.request("POST", "/predict", body=body,
                               headers={"Content-Type": content_type, "Content-Length": str(len(body)),
                                        "X-Request-ID": request_id})
            response = connection.getresponse()
            payload = response.read(262145)
            if response.status != 200:
                raise CaptureError(502, "prediction_upstream_failed", "The existing recognition service could not process this image")
            if len(payload) > 262144:
                raise CaptureError(502, "prediction_response_too_large", "The recognition response exceeded its size limit")
            try:
                result = json.loads(payload)
            except (ValueError, UnicodeDecodeError):
                raise CaptureError(502, "invalid_prediction_response", "The recognition response was not valid JSON") from None
            if not isinstance(result, dict) or not isinstance(result.get("predicted_class"), str):
                raise CaptureError(502, "invalid_prediction_response", "The recognition response has an unexpected structure")
            if (type(result.get("is_valid")) is not bool or type(result.get("confidence")) not in (float, int)
                    or not 0 <= result["confidence"] <= 1):
                raise CaptureError(502, "invalid_prediction_response", "The recognition response has invalid decision fields")
            allowed = ("predicted_class", "confidence", "is_valid", "message", "top3_predictions")
            return {key: result[key] for key in allowed if key in result}
        except (TimeoutError, OSError, http.client.HTTPException) as exc:
            raise CaptureError(504 if isinstance(exc, TimeoutError) else 502,
                               "prediction_unavailable", "The recognition service is temporarily unavailable") from None
        finally:
            connection.close()


class CaptureServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, state):
        self.state = state
        super().__init__(address, CaptureHandler)


class CaptureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "HoloLensCapture/" + VERSION
    sys_version = ""

    @property
    def state(self):
        return self.server.state

    def log_message(self, format, *args):
        # BaseHTTPRequestHandler's default log includes the query token. Never use it.
        path = urlsplit(self.path).path
        print(json.dumps({"time": utc_now(), "method": self.command, "path": path,
                          "status": str(args[1]) if len(args) > 1 else "-"}), flush=True)

    def send_payload(self, status, body, content_type="application/json; charset=utf-8", extra=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Permissions-Policy", "camera=(self), microphone=()")
        self.send_header("Connection", "close")
        for name, value in (extra or {}).items():
            self.send_header(name, str(value))
        self.end_headers()
        self.close_connection = True
        if self.command != "HEAD":
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def send_json(self, status, value):
        self.send_payload(status, json.dumps(value, ensure_ascii=False, allow_nan=False).encode("utf-8"))

    def auth(self):
        query = parse_qs(urlsplit(self.path).query)
        token = self.headers.get("X-HoloLens-Token", "")
        run_id = self.headers.get("X-HoloLens-Run", "")
        if self.command in ("GET", "HEAD"):
            token = token or query.get("token", [""])[0]
            run_id = run_id or query.get("run", [""])[0]
        if not token or not hmac.compare_digest(token.encode("utf-8"), self.state.session["token"].encode("ascii")):
            raise CaptureError(401, "capture_session_required", "Open the capture application with its current session link")
        if time.time() >= self.state.session["expires_epoch"]:
            raise CaptureError(401, "capture_session_expired", "The capture test session has expired")
        if run_id != self.state.session["run_id"]:
            raise CaptureError(403, "capture_run_mismatch", "The capture run identifier does not match")

    def read_body(self, limit):
        if self.headers.get("Transfer-Encoding"):
            raise CaptureError(400, "transfer_encoding_unsupported", "Send a bounded Content-Length request")
        try:
            size = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            raise CaptureError(400, "invalid_content_length", "Invalid request length") from None
        if size < 0:
            raise CaptureError(411, "content_length_required", "Content-Length is required")
        if size > limit:
            raise CaptureError(413, "request_too_large", "The request exceeds the capture size limit")
        self.connection.settimeout(15)
        body = self.rfile.read(size)
        if len(body) != size:
            raise CaptureError(400, "incomplete_request", "The request body was incomplete")
        return body

    def do_GET(self):
        self.route_get()

    def do_HEAD(self):
        self.route_get()

    def route_get(self):
        try:
            path = unquote(urlsplit(self.path).path)
            if path == PREFIX + "api/health":
                self.send_json(200, {"status": "ok", "version": VERSION,
                                     "started_at": self.state.started_at, "prediction_backend": "existing-v2-loopback"})
                return
            if path in (PREFIX + "api/evidence", PREFIX + "api/capture"):
                self.auth()
                with self.state.lock:
                    if path.endswith("/evidence"):
                        self.send_json(200, self.state.evidence)
                    else:
                        latest = self.state.evidence["latest_prediction"]
                        requested = parse_qs(urlsplit(self.path).query).get("prediction_id", [None])[0]
                        if not latest or not self.state.image_path.is_file():
                            raise CaptureError(404, "capture_not_available", "No new capture has completed")
                        if requested is not None and requested != latest["prediction_id"]:
                            raise CaptureError(409, "capture_replaced", "A newer capture replaced this image")
                        image = self.state.image_path.read_bytes()
                        if hashlib.sha256(image).hexdigest() != latest["image_sha256"]:
                            raise CaptureError(500, "capture_integrity_error", "Capture evidence integrity check failed")
                        self.send_payload(200, image, latest["content_type"],
                                          {"X-HoloLens-Image-SHA256": latest["image_sha256"],
                                           "X-HoloLens-Prediction-ID": latest["prediction_id"]})
                return
            if not path.startswith(PREFIX) or path.startswith(PREFIX + "api/"):
                raise CaptureError(404, "not_found", "Not found")
            relative = path[len(PREFIX):] or "index.html"
            asset = (self.state.web_root / relative).resolve()
            if (not asset.is_relative_to(self.state.web_root) or not asset.is_file()
                    or asset.suffix.lower() not in (".html", ".js", ".css", ".svg", ".png", ".ico", ".webmanifest")):
                raise CaptureError(404, "not_found", "Not found")
            self.send_payload(200, asset.read_bytes(), mimetypes.guess_type(asset.name)[0] or "application/octet-stream")
        except CaptureError as exc:
            self.send_json(exc.status, {"error": exc.code, "message": exc.message})
        except (OSError, ValueError):
            self.send_json(500, {"error": "capture_read_failed", "message": "Capture state is temporarily unavailable"})

    def do_POST(self):
        try:
            self.auth()
            path = urlsplit(self.path).path
            if path == PREFIX + "api/events":
                if not self.headers.get("Content-Type", "").lower().startswith("application/json"):
                    raise CaptureError(415, "json_required", "Use application/json")
                try:
                    event = json.loads(self.read_body(MAX_EVENT_BYTES))
                except (ValueError, UnicodeDecodeError):
                    raise CaptureError(422, "invalid_json", "Invalid event JSON") from None
                if not isinstance(event, dict) or event.get("run_id") != self.state.session["run_id"]:
                    raise CaptureError(422, "invalid_event", "Event run_id must match this capture session")
                sequence = self.state.record_event(event.get("event"), event.get("request_id"), event.get("details"),
                                                   self.headers.get("User-Agent", ""))
                self.send_json(200, {"ok": True, "sequence": sequence})
                return
            if path != PREFIX + "api/predict":
                raise CaptureError(404, "not_found", "Not found")
            request_id = self.headers.get("X-Request-ID") or uuid.uuid4().hex
            if not IDENTIFIER.fullmatch(request_id):
                raise CaptureError(422, "invalid_request_id", "Invalid request identifier")
            body = self.read_body(MAX_UPLOAD_BYTES)
            content_type = self.headers.get("Content-Type", "")
            image, image_type, extension = parse_capture(body, content_type)
            image_hash = hashlib.sha256(image).hexdigest()
            supplied_hash = self.headers.get("X-HoloLens-Image-SHA256")
            if supplied_hash and not hmac.compare_digest(supplied_hash.lower(), image_hash):
                raise CaptureError(422, "capture_hash_mismatch", "The uploaded image hash does not match")
            with self.state.lock:
                latest = self.state.evidence["latest_prediction"]
                if latest and latest["request_id"] == request_id:
                    if latest["image_sha256"] != image_hash:
                        raise CaptureError(409, "request_image_mismatch", "A request identifier cannot be reused for another image")
                    self.send_json(200, latest["response"])
                    return
            if not self.state.inference_slot.acquire(blocking=False):
                raise CaptureError(429, "prediction_busy", "One capture is already being recognized")
            try:
                received_at = utc_now()
                self.state.record_event("server_capture_received", request_id,
                                        {"image_sha256": image_hash, "image_bytes": len(image)},
                                        self.headers.get("User-Agent", ""))
                start = time.monotonic()
                result = self.state.forward(body, content_type, request_id)
                proof = {"request_id": request_id, "run_id": self.state.session["run_id"],
                         "image_sha256": image_hash, "prediction_id": uuid.uuid4().hex,
                         "received_at": received_at, "completed_at": utc_now(),
                         "upstream_elapsed_ms": round((time.monotonic() - start) * 1000, 2)}
                response = dict(result, capture_evidence=proof)
                with self.state.lock:
                    temporary = self.state.image_path.with_suffix(".tmp")
                    temporary.write_bytes(image)
                    os.chmod(temporary, 0o600)
                    os.replace(temporary, self.state.image_path)
                    self.state.evidence["latest_prediction"] = dict(
                        proof, content_type=image_type, extension=extension, image_bytes=len(image), response=response,
                        user_agent=self.state.redact(self.headers.get("User-Agent", "")))
                    self.state.save()
                self.state.record_event("server_prediction_completed", request_id,
                                        {"image_sha256": image_hash, "prediction_id": proof["prediction_id"],
                                         "accepted": result["is_valid"], "class_name": result["predicted_class"],
                                         "confidence": result["confidence"]})
                self.send_json(200, response)
            finally:
                self.state.inference_slot.release()
        except CaptureError as exc:
            self.send_json(exc.status, {"error": exc.code, "message": exc.message})
        except (OSError, ValueError):
            self.send_json(500, {"error": "capture_processing_failed", "message": "The capture could not be completed"})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    issue = sub.add_parser("issue-session")
    issue.add_argument("--session-file", required=True)
    issue.add_argument("--run-id")
    issue.add_argument("--ttl", type=int, default=86400)
    issue.add_argument("--replace", action="store_true")
    info = sub.add_parser("session-info")
    info.add_argument("--session-file", required=True)
    info.add_argument("--launch-url", action="store_true")
    serve = sub.add_parser("serve")
    serve.add_argument("--session-file", required=True)
    serve.add_argument("--data-dir", required=True)
    serve.add_argument("--web-root", required=True)
    serve.add_argument("--host", default="127.0.0.1", choices=("127.0.0.1",))
    serve.add_argument("--port", type=int, default=9012)
    serve.add_argument("--upstream", default="http://127.0.0.1:8002")
    args = parser.parse_args()
    if args.command == "issue-session":
        session = issue_session(args.session_file, args.run_id, args.ttl, args.replace)
        print(json.dumps({key: value for key, value in session.items() if key != "token"}))
    elif args.command == "session-info":
        session = json.loads(Path(args.session_file).read_text(encoding="utf-8"))
        if args.launch_url:
            print("https://rice-srt.cn/hololens/?run=" + session["run_id"] + "&token=" + session["token"])
        else:
            print(json.dumps({key: value for key, value in session.items() if key != "token"}))
    else:
        session = json.loads(Path(args.session_file).read_text(encoding="utf-8"))
        server = CaptureServer((args.host, args.port), CaptureState(session, args.data_dir, args.web_root, args.upstream))
        print(json.dumps({"status": "listening", "address": args.host, "port": args.port,
                          "version": VERSION, "run_id": session["run_id"]}), flush=True)
        try:
            server.serve_forever()
        finally:
            server.server_close()


if __name__ == "__main__":
    main()
