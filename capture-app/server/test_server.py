"""Meaningful HTTP contract tests using an isolated fake recognition service."""
import base64
import concurrent.futures
import hashlib
import http.client
import json
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from server import CaptureServer, CaptureState, issue_session


PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6QmcAAAAASUVORK5CYII=")


def multipart(image=PNG):
    boundary = "capture-http-test-boundary"
    return (b"--" + boundary.encode() + b'\r\nContent-Disposition: form-data; name="file"; filename="capture.png"\r\n'
            b"Content-Type: image/png\r\n\r\n" + image + b"\r\n--" + boundary.encode() + b"--\r\n",
            "multipart/form-data; boundary=" + boundary)


class FakePredictionHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        self.server.calls.append({"path": self.path, "body": body, "content_type": self.headers["Content-Type"]})
        self.server.received.set()
        if self.server.wait_for_release:
            self.server.release.wait(5)
        if self.server.fail:
            self.send_response(500)
            data = b'{"detail":"/private/backend/path is unavailable"}'
        else:
            self.send_response(200)
            data = json.dumps({"predicted_class": "其他", "confidence": 0.91, "is_valid": False,
                               "message": "其他/未知类别", "top3_predictions": [["其他", 0.91]]}).encode()
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class CaptureContractTests(unittest.TestCase):
    def setUp(self):
        test_root = Path(__file__).resolve().parent / ".test-tmp"
        test_root.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="hololens-capture-tests-", dir=test_root)
        self.root = Path(self.temp.name)
        self.web = self.root / "web"
        self.web.mkdir()
        (self.web / "index.html").write_text("<html>camera test</html>", encoding="utf-8")
        (self.root / "private.json").write_text('{"private":true}', encoding="utf-8")
        self.session = issue_session(self.root / "session.json", "test-run", ttl=3600)
        self.upstream = ThreadingHTTPServer(("127.0.0.1", 0), FakePredictionHandler)
        self.upstream.calls, self.upstream.fail = [], False
        self.upstream.wait_for_release = False
        self.upstream.received, self.upstream.release = threading.Event(), threading.Event()
        self.upstream_thread = threading.Thread(target=self.upstream.serve_forever, daemon=True)
        self.upstream_thread.start()
        self.state = CaptureState(self.session, self.root / "data", self.web,
                                  "http://127.0.0.1:" + str(self.upstream.server_port))
        self.gateway = CaptureServer(("127.0.0.1", 0), self.state)
        self.gateway_thread = threading.Thread(target=self.gateway.serve_forever, daemon=True)
        self.gateway_thread.start()

    def tearDown(self):
        self.upstream.release.set()
        self.gateway.shutdown()
        self.gateway.server_close()
        self.upstream.shutdown()
        self.upstream.server_close()
        self.gateway_thread.join(2)
        self.upstream_thread.join(2)
        self.temp.cleanup()

    def request(self, method, path, body=None, content_type=None, authenticated=True, request_id="test-image-1", extra=None):
        headers = {"User-Agent": "HoloLens-Contract-Test"}
        if authenticated:
            headers.update({"X-HoloLens-Token": self.session["token"], "X-HoloLens-Run": "test-run"})
        if content_type:
            headers["Content-Type"] = content_type
        if request_id:
            headers["X-Request-ID"] = request_id
        headers.update(extra or {})
        connection = http.client.HTTPConnection("127.0.0.1", self.gateway.server_port, timeout=5)
        try:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            data = response.read()
            return response.status, dict(response.getheaders()), data
        finally:
            connection.close()

    def predict(self, image=PNG, request_id="test-image-1"):
        body, content_type = multipart(image)
        return self.request("POST", "/hololens/api/predict", body, content_type, request_id=request_id)

    def test_new_image_roundtrip_and_render_event_are_correlated(self):
        body, content_type = multipart()
        status, _, raw = self.request("POST", "/hololens/api/predict", body, content_type)
        self.assertEqual(status, 200)
        result = json.loads(raw)
        self.assertFalse(result["is_valid"])
        proof = result["capture_evidence"]
        self.assertEqual(proof["image_sha256"], hashlib.sha256(PNG).hexdigest())
        self.assertEqual(proof["request_id"], "test-image-1")
        self.assertEqual(self.upstream.calls, [{"path": "/predict", "body": body, "content_type": content_type}])
        event = {"event": "result_rendered", "run_id": "test-run", "request_id": proof["request_id"],
                 "details": {"image_sha256": proof["image_sha256"], "prediction_id": proof["prediction_id"], "accepted": False}}
        self.assertEqual(self.request("POST", "/hololens/api/events", json.dumps(event), "application/json")[0], 200)
        status, _, raw = self.request("GET", "/hololens/api/evidence")
        evidence = json.loads(raw)
        self.assertEqual(status, 200)
        self.assertEqual(evidence["latest_prediction"]["prediction_id"], proof["prediction_id"])
        self.assertEqual(evidence["events"][-1]["event"], "result_rendered")
        status, headers, capture = self.request("GET", "/hololens/api/capture?prediction_id=" + proof["prediction_id"])
        self.assertEqual(status, 200)
        self.assertEqual(capture, PNG)
        self.assertEqual(headers["X-HoloLens-Image-SHA256"], proof["image_sha256"])

    def test_authentication_is_required_before_forwarding_or_evidence(self):
        body, content_type = multipart()
        self.assertEqual(self.request("POST", "/hololens/api/predict", body, content_type, authenticated=False)[0], 401)
        self.assertEqual(self.request("GET", "/hololens/api/evidence", authenticated=False)[0], 401)
        self.assertEqual(self.request("GET", "/hololens/api/capture", authenticated=False)[0], 401)
        self.assertEqual(self.upstream.calls, [])
        self.assertEqual(self.request("GET", "/hololens/api/evidence", extra={"X-HoloLens-Run": "another-run"})[0], 403)
        self.state.session["expires_epoch"] = time.time() - 1
        self.assertEqual(self.request("GET", "/hololens/api/evidence")[0], 401)

    def test_duplicate_request_is_cached_and_changed_image_is_rejected(self):
        first = self.predict()
        second = self.predict()
        self.assertEqual(first[2], second[2])
        self.assertEqual(len(self.upstream.calls), 1)
        self.assertEqual(self.predict(PNG + b"changed")[0], 409)
        self.assertEqual(len(self.upstream.calls), 1)

    def test_invalid_image_and_false_hash_never_reach_model(self):
        self.assertEqual(self.predict(b"not an image")[0], 415)
        body, content_type = multipart()
        self.assertEqual(self.request("POST", "/hololens/api/predict", body, content_type,
                                      extra={"X-HoloLens-Image-SHA256": "0" * 64})[0], 422)
        self.assertEqual(self.request("POST", "/hololens/api/predict", b"x", "application/json")[0], 415)
        self.assertEqual(self.upstream.calls, [])

    def test_second_inflight_image_receives_busy_without_duplicate_inference(self):
        self.upstream.wait_for_release = True
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            first = pool.submit(self.predict)
            self.assertTrue(self.upstream.received.wait(2))
            self.assertEqual(self.predict(request_id="test-image-2")[0], 429)
            self.upstream.release.set()
            self.assertEqual(first.result(timeout=3)[0], 200)
        self.assertEqual(len(self.upstream.calls), 1)

    def test_upstream_errors_do_not_disclose_backend_details_or_create_result(self):
        self.upstream.fail = True
        status, _, data = self.predict()
        self.assertEqual(status, 502)
        self.assertNotIn(b"/private/backend", data)
        self.assertIsNone(self.state.evidence["latest_prediction"])

    def test_static_paths_cannot_expose_state_or_parent_files(self):
        self.assertEqual(self.request("GET", "/hololens/", authenticated=False)[0], 200)
        self.assertEqual(self.request("GET", "/hololens/api/health", authenticated=False)[0], 200)
        self.assertEqual(self.request("GET", "/hololens/%2e%2e/private.json", authenticated=False)[0], 404)
        self.assertEqual(self.request("GET", "/hololens/session.json", authenticated=False)[0], 404)

    def test_event_tokens_are_redacted_and_only_small_scalar_details_are_saved(self):
        event = {"event": "camera_ready", "run_id": "test-run", "request_id": None,
                 "details": {"message": "token=" + self.session["token"], "token": self.session["token"],
                             "image": "raw data", "width": 1920, "nested": {"a": 1}}}
        self.assertEqual(self.request("POST", "/hololens/api/events", json.dumps(event), "application/json")[0], 200)
        saved = self.state.evidence_path.read_text(encoding="utf-8")
        self.assertNotIn(self.session["token"], saved)
        self.assertNotIn("raw data", saved)
        self.assertEqual(self.state.evidence["events"][-1]["details"]["width"], 1920)
        self.assertNotIn("nested", self.state.evidence["events"][-1]["details"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
