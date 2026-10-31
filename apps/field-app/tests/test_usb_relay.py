import http.client
import importlib.util
import json
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('field_relay', ROOT / 'server/usb_relay.py')
relay = importlib.util.module_from_spec(spec)
sys.modules['field_relay'] = relay
spec.loader.exec_module(relay)


class Upstream(BaseHTTPRequestHandler):
    calls = []

    def do_GET(self):
        self.__class__.calls.append((self.path, dict(self.headers)))
        body = json.dumps({'status': 'ok', 'path': self.path}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        self.__class__.calls.append((self.path, dict(self.headers), body))
        payload = json.dumps({'ok': True, 'bytes': len(body)}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


class Tests(unittest.TestCase):
    def setUp(self):
        Upstream.calls = []
        self.upstream = ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        threading.Thread(target=self.upstream.serve_forever, daemon=True).start()
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), relay.Handler)
        self.server.daemon_threads = True
        self.server.relay = relay.Relay('127.0.0.1', 'http', self.upstream.server_port)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.server.shutdown(); self.server.server_close()
        self.upstream.shutdown(); self.upstream.server_close()

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=5)
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        payload = response.read()
        connection.close()
        return response.status, dict(response.getheaders()), payload

    def test_path_allowlist(self):
        self.assertTrue(relay.allowed_path('/hololens-app/api/health'))
        self.assertTrue(relay.allowed_path('/hololens-app/api/dynamic/frame'))
        self.assertFalse(relay.allowed_path('/hololens/api/predict'))
        self.assertFalse(relay.allowed_path('/'))
        status, _, payload = self.request('GET', '/hololens/api/health')
        self.assertEqual(status, 404)
        self.assertIn(b'not allowed', payload)

    def test_headers_and_get_are_forwarded_without_secrets(self):
        status, headers, payload = self.request('GET', '/hololens-app/api/health?x=1', headers={
            'Authorization': 'Bearer secret', 'X-Frame-ID': 'frame-1',
            'X-Image-SHA256': 'a' * 64, 'X-Unknown': 'drop-me'})
        self.assertEqual(status, 200)
        self.assertEqual(headers['X-Rice-Relay'], 'usb')
        self.assertEqual(json.loads(payload)['path'], '/hololens-app/api/health?x=1')
        call = Upstream.calls[0]
        self.assertEqual(call[1]['Authorization'], 'Bearer secret')
        self.assertEqual(call[1]['X-Frame-ID'], 'frame-1')
        self.assertNotIn('X-Unknown', call[1])

    def test_post_body_is_forwarded(self):
        body = b'\xff\xd8\xffframebytes'
        status, headers, payload = self.request('POST', '/hololens-app/api/dynamic/frame', body=body,
                                                headers={'Content-Type': 'image/jpeg',
                                                         'X-Frame-ID': 'frame-2',
                                                         'X-Image-SHA256': 'b' * 64})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(payload)['bytes'], len(body))
        self.assertEqual(Upstream.calls[0][2], body)
        self.assertEqual(Upstream.calls[0][1]['Content-Type'], 'image/jpeg')

    def test_upstream_failure_becomes_504_not_a_fake_result(self):
        self.server.relay = relay.Relay('127.0.0.1', 'http', 1)
        status, _, payload = self.request('GET', '/hololens-app/api/health')
        self.assertEqual(status, 504)
        self.assertIn(b'relay_timeout', payload)


if __name__ == '__main__':
    unittest.main()
