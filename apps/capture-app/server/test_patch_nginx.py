import unittest

from patch_nginx import INCLUDE, patch_config


CONFIG = '''server {
    listen 80 default_server;
    server_name rice-srt.cn www.rice-srt.cn;
    location / { return 301 https://$host$request_uri; }
}
server {
    listen 443 ssl default_server;
    server_name rice-srt.cn www.rice-srt.cn;
    ssl_certificate /existing/fullchain.pem;
    ssl_certificate_key /existing/privkey.pem;
    location /relay/ { proxy_pass http://127.0.0.1:9000/; }
    location / { proxy_pass http://127.0.0.1:8002; }
}
'''


class NginxPatchTests(unittest.TestCase):
    def test_only_tls_server_gains_one_idempotent_include(self):
        patched = patch_config(CONFIG)
        insertion = "\n    # Isolated HoloLens single-photo capture gateway\n" + INCLUDE
        self.assertEqual(patched.replace(insertion, "", 1), CONFIG)
        self.assertEqual(patched.count(INCLUDE), 1)
        self.assertGreater(patched.index(INCLUDE), patched.index("listen 80"))
        self.assertEqual(patch_config(patched), patched)
        self.assertIn("location /relay/ { proxy_pass http://127.0.0.1:9000/; }", patched)

    def test_ambiguous_or_preexisting_manual_location_is_refused(self):
        with self.assertRaises(ValueError):
            patch_config(CONFIG + CONFIG)
        with self.assertRaises(ValueError):
            patch_config(CONFIG.replace("location /relay/", "location /hololens/"))
        with self.assertRaises(ValueError):
            patch_config(CONFIG.replace("listen 443 ssl", "listen 9443 ssl"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
