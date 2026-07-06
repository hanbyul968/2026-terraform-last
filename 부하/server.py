"""
부하 테스트 프록시 서버
- 정적 파일 서빙 (index.html, app.js 등)
- /proxy?url=... 로 요청하면 대신 HTTP 요청 후 응답 전달 (CORS 우회)

사용법:
  python server.py
  브라우저에서 http://localhost:9000 접속
"""
import http.server
import urllib.request
import urllib.error
import urllib.parse
import json
import time
import sys
import os

PORT = 9000

class ProxyHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/proxy?'):
            self._handle_proxy('GET')
        else:
            super().do_GET()

    def do_POST(self):
        if self.path.startswith('/proxy?'):
            self._handle_proxy('POST')
        else:
            self.send_error(404)

    def do_PUT(self):
        if self.path.startswith('/proxy?'):
            self._handle_proxy('PUT')
        else:
            self.send_error(404)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PUT, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def _handle_proxy(self, method):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        target_url = params.get('url', [''])[0]

        if not target_url:
            self.send_error(400, 'Missing url parameter')
            return

        # Read body for POST/PUT
        body = None
        content_type = self.headers.get('Content-Type', '')
        if method in ('POST', 'PUT'):
            length = int(self.headers.get('Content-Length', 0))
            if length > 0:
                body = self.rfile.read(length)

        try:
            req = urllib.request.Request(target_url, data=body, method=method)
            if content_type:
                req.add_header('Content-Type', content_type)

            start = time.time()
            with urllib.request.urlopen(req, timeout=5) as resp:
                resp_body = resp.read()
                status = resp.status
                elapsed = int((time.time() - start) * 1000)
        except urllib.error.HTTPError as e:
            resp_body = e.read() if e.fp else b''
            status = e.code
            elapsed = int((time.time() - start) * 1000)
        except Exception as e:
            # Timeout or connection error
            result = json.dumps({'error': str(e), 'status': 0, 'ms': 5000}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Content-Length', len(result))
            self.end_headers()
            self.wfile.write(result)
            return

        # Wrap response with metadata
        result = json.dumps({
            'status': status,
            'ms': elapsed,
            'body': resp_body.decode('utf-8', errors='replace')[:2000]
        }).encode()

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Content-Length', len(result))
        self.end_headers()
        self.wfile.write(result)

    def log_message(self, format, *args):
        # Suppress noisy logs for static files, only show proxy
        if '/proxy?' in str(args[0]):
            sys.stderr.write(f"[proxy] {args[0]}\n")


if __name__ == '__main__':
    os.chdir(os.path.dirname(os.path.abspath(__file__)) or '.')
    server = http.server.ThreadingHTTPServer(('', PORT), ProxyHandler)
    print(f'=== Load Test Proxy Server (threaded) ===')
    print(f'http://localhost:{PORT}')
    print(f'Press Ctrl+C to stop')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\nStopped.')
