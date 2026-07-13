#!/usr/bin/env bash
set -euo pipefail

install -d -m 0755 /opt/skills-lattice/service

# === 제공 배포파일 service_app.py (수정 없이 그대로 배포) ===
cat > /opt/skills-lattice/service/service_app.py <<'PYAPP'
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


class ServiceHandler(BaseHTTPRequestHandler):
    def _send_json(self, status_code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self._send_json(200, {"status": "ok", "app": "service"})
            return

        if parsed.path == "/v1/orders":
            order_id = parse_qs(parsed.query).get("id", ["1001"])[0]
            self._send_json(200, {"order_id": order_id, "via": "vpc-lattice"})
            return

        self._send_json(404, {"error": "not found"})


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", 8080), ServiceHandler)
    server.serve_forever()
PYAPP

chmod 0644 /opt/skills-lattice/service/service_app.py

cat > /etc/systemd/system/lattice-order-service-app.service <<'UNIT'
[Unit]
Description=Skills VPC Lattice Order Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/skills-lattice/service/service_app.py
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lattice-order-service-app.service
