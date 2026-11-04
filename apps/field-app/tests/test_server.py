import http.client
import importlib.util
from pathlib import Path
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


gateway = load('retired_gateway', ROOT / 'server/server.py')
retirement = load('retired_mount', ROOT / 'server/retire_dynamic.py')


class RetirementTests(unittest.TestCase):
    def test_old_dynamic_routes_are_gone_without_contacting_a_model(self):
        with tempfile.TemporaryDirectory() as folder:
            server = gateway.Server(('127.0.0.1', 0), gateway.Store(folder, 'http://127.0.0.1:1', 'a' * 48))
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                for method, path in [('GET', '/dynamic/health'), ('POST', '/dynamic/frame')]:
                    connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=2)
                    connection.request(method, gateway.PREFIX + path)
                    response = connection.getresponse()
                    self.assertEqual(response.status, 404)
                    response.read()
                    connection.close()
                self.assertFalse(hasattr(server.store, 'dynamic_frame'))
            finally:
                server.shutdown()
                server.server_close()
                worker.join()

    def test_retirement_preserves_independent_api_and_is_idempotent(self):
        base = 'app = object()\n# independent classifier\ndef classify(): return 1\n'
        self.assertEqual(retirement.retire(base + retirement.MOUNT), base)
        self.assertEqual(retirement.retire(base), base)

    def test_partial_unrecognized_mount_is_not_silently_removed(self):
        with self.assertRaises(ValueError):
            retirement.retire('from api.dynamic import install_dynamic as _install_rice_dynamic\n')


if __name__ == '__main__':
    unittest.main()
