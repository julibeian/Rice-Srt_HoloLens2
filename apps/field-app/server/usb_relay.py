#!/usr/bin/env python3
"""Local USB relay for the HoloLens field app (development fallback).

The glasses can reach this PC at the USB NCM host address but the current
campus Wi-Fi blocks outbound TLS. This relay binds only to the USB host
address, accepts the app's `/hololens-app/api/` traffic over the private USB
link, and forwards it to the production HTTPS origin with normal certificate
verification. It is a development bridge, not a replacement for the direct
glasses-to-cloud path.

Only the application API and `/health` are proxied. Request bodies and the
Authorization header are forwarded in memory and never logged or stored.
"""
from __future__ import annotations

import argparse
import http.client
import json
import ssl
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

ALLOWED_PREFIX = '/hololens-app/api/'
MAX_BODY = 10 * 1024 * 1024
MAX_RESPONSE = 2 * 1024 * 1024
FORWARD_HEADERS = (
    'authorization', 'content-type', 'x-request-id', 'x-image-sha256',
    'x-frame-id', 'x-dynamic-size', 'user-agent', 'accept',
)


def allowed_path(path):
    return path == ALLOWED_PREFIX + 'health' or path.startswith(ALLOWED_PREFIX)


def forward_headers(headers):
    return {key: value for key, value in headers.items()
            if key.lower() in FORWARD_HEADERS}


class Relay:
    def __init__(self, host, scheme='https', port=None):
        self.host = host
        self.scheme = scheme
        self.port = port

    def request(self, method, path, body, headers):
        port = self.port or (443 if self.scheme == 'https' else 80)
        if self.scheme == 'https':
            connection = http.client.HTTPSConnection(
                self.host, port, timeout=30, context=ssl.create_default_context())
        else:
            connection = http.client.HTTPConnection(self.host, port, timeout=30)
        try:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            payload = response.read(MAX_RESPONSE + 1)
            if len(payload) > MAX_RESPONSE:
                raise ValueError('response too large')
            return response.status, dict(response.getheaders()), payload
        finally:
            connection.close()


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'RiceUsbRelay/1.0'
    sys_version = ''

    def log_message(self, fmt, *args):
        print(json.dumps({'at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                          'method': self.command,
                          'path': urlsplit(self.path).path,
                          'status': str(args[1]) if len(args) > 1 else ''}),
              flush=True)

    def send_json(self, status, value):
        body = json.dumps(value, ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def read_body(self):
        if self.headers.get('Transfer-Encoding'):
            raise ValueError('length required')
        try:
            length = int(self.headers.get('Content-Length', '0'))
        except ValueError:
            raise ValueError('invalid length') from None
        if length < 0 or length > MAX_BODY:
            raise ValueError('body too large')
        body = self.rfile.read(length) if length else b''
        if len(body) != length:
            raise ValueError('incomplete body')
        return body

    def relay(self):
        parsed = urlsplit(self.path)
        if not allowed_path(parsed.path):
            self.send_json(404, {'error': 'not_found', 'message': 'relay path not allowed'})
            return
        try:
            body = self.read_body()
        except ValueError as error:
            status = 413 if 'too large' in str(error) else 411 if 'length' in str(error) else 400
            self.send_json(status, {'error': 'invalid_body', 'message': str(error)})
            return
        headers = forward_headers(self.headers)
        headers['Host'] = self.server.relay.host
        started = time.monotonic()
        try:
            status, response_headers, payload = self.server.relay.request(
                self.command, parsed.path + (('?' + parsed.query) if parsed.query else ''),
                body if self.command not in ('GET', 'HEAD') else None, headers)
        except (OSError, TimeoutError, http.client.HTTPException):
            self.send_json(504, {'error': 'relay_timeout', 'message': '云端连接超时'})
            return
        except Exception:
            self.send_json(502, {'error': 'relay_failed', 'message': '云端连接失败'})
            return
        self.send_response(status)
        for key, value in response_headers.items():
            if key.lower() in ('content-type', 'content-length', 'cache-control'):
                self.send_header(key, value)
        if 'content-length' not in {key.lower() for key in response_headers}:
            self.send_header('Content-Length', str(len(payload)))
        self.send_header('X-Rice-Relay', 'usb')
        self.send_header('X-Rice-Relay-Ms', str(round((time.monotonic() - started) * 1000, 1)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(payload)

    def do_GET(self):
        self.relay()

    def do_POST(self):
        self.relay()


class RelayServer(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        # The app cancels in-flight frames when the user stops dynamic mode;
        # those resets are expected and must not flood the relay log.
        import sys
        if isinstance(sys.exc_info()[1], (ConnectionResetError, BrokenPipeError)):
            return
        super().handle_error(request, client_address)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', default='169.254.216.241')
    parser.add_argument('--port', type=int, default=9021)
    parser.add_argument('--upstream', default='rice-srt.cn')
    parser.add_argument('--test-upstream-scheme', default='https', choices=('http', 'https'))
    args = parser.parse_args()
    server = RelayServer((args.host, args.port), Handler)
    server.relay = Relay(args.upstream, args.test_upstream_scheme)
    print(json.dumps({'relay': 'listening', 'host': args.host, 'port': args.port,
                      'upstream': args.upstream, 'scheme': args.test_upstream_scheme}), flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
