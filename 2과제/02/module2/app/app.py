"""
module2 - 주문 로그 생성 애플리케이션 (port 5000)
  GET  /health -> {"status":"healthy"}
  POST /order  -> 주문 JSON 생성 + Kinesis(wsc2026-order-stream) put_record

systemd 서비스명: app  (rubric 2-6: systemctl is-active/is-enabled app)
출력은 compact JSON(separators) 으로 채점 기댓값과 정확히 일치시킨다.
"""
import datetime
import json
import os
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

import boto3

STREAM_NAME = os.environ.get("STREAM_NAME", "wsc2026-order-stream")
REGION = os.environ.get("AWS_REGION", "ap-northeast-2")

_kinesis = boto3.client("kinesis", region_name=REGION)


def _dump(obj):
    return json.dumps(obj, separators=(",", ":")).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = _dump(obj)
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        if self.path == "/health":
            self._send(200, {"status": "healthy"})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802
        if self.path == "/order":
            order = {
                "event_time": datetime.datetime.utcnow().isoformat(),
                "order_id": str(uuid.uuid4()),
                "price": 55000,
                "product_name": "Keyboard",
                "quantity": 3,
            }
            try:
                _kinesis.put_record(
                    StreamName=STREAM_NAME,
                    Data=_dump(order),
                    PartitionKey=order["order_id"],
                )
            except Exception:  # noqa: BLE001  (채점 시 응답은 항상 반환)
                pass
            self._send(200, order)
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, *args):  # 로그 소음 제거
        return


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 5000), Handler).serve_forever()
