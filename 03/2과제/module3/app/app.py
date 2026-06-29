# -*- coding: utf-8 -*-
# log-generator : JSON 로그를 stdout 으로 출력하는 샘플 애플리케이션
#   GET /health                       -> 헬스체크
#   GET /info | /warn | /error        -> 해당 레벨 로그 1건
#   GET /burst?count=N&level=LEVEL    -> 지정 레벨 로그 N건
# 로그 형식: {"timestamp":"...","level":"ERROR","message":"...","service":"log-generator"}
import json
import sys
import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

SERVICE = "log-generator"
PORT = 8080

MESSAGES = {
    "INFO": "Request processed successfully",
    "WARN": "High latency detected on request",
    "ERROR": "Failed to connect to database",
}


def emit(level):
    rec = {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "level": level,
        "message": MESSAGES.get(level, "log message"),
        "service": SERVICE,
    }
    sys.stdout.write(json.dumps(rec) + "\n")
    sys.stdout.flush()


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        return  # access 로그 억제 (앱 JSON 로그만 출력)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)

        if path == "/health":
            self._send(200, {"status": "ok"})
        elif path == "/info":
            emit("INFO")
            self._send(200, {"emitted": "INFO", "count": 1})
        elif path == "/warn":
            emit("WARN")
            self._send(200, {"emitted": "WARN", "count": 1})
        elif path == "/error":
            emit("ERROR")
            self._send(200, {"emitted": "ERROR", "count": 1})
        elif path == "/burst":
            level = qs.get("level", ["INFO"])[0].upper()
            count = int(qs.get("count", ["1"])[0])
            for _ in range(count):
                emit(level)
            self._send(200, {"emitted": level, "count": count})
        else:
            self._send(404, {"error": "not found"})


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
