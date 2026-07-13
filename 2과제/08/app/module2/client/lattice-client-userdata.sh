#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="ap-northeast-1"
SERVICE_NAME="skills-lattice-order-service"

install -d -m 0755 /opt/skills-lattice/client

# === 제공 배포파일 client_app.py (수정 없이 그대로 배포) ===
cat > /opt/skills-lattice/client/client_app.py <<'PYAPP'
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen


SERVICE_URL = os.environ.get("SERVICE_URL", "").rstrip("/")


class ClientHandler(BaseHTTPRequestHandler):
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
            self._send_json(200, {"status": "ok", "app": "client"})
            return

        if parsed.path == "/v1/client/orders":
            order_id = parse_qs(parsed.query).get("id", ["1001"])[0]
            if not SERVICE_URL:
                self._send_json(500, {"error": "SERVICE_URL is not configured"})
                return
            request = Request(f"{SERVICE_URL}/v1/orders?id={order_id}")
            with urlopen(request, timeout=5) as response:
                service_payload = json.loads(response.read().decode("utf-8"))
            self._send_json(200, {"client": "ok", "service": service_payload})
            return

        self._send_json(404, {"error": "not found"})


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", 80), ClientHandler)
    server.serve_forever()
PYAPP

chmod 0644 /opt/skills-lattice/client/client_app.py

# === SERVICE_URL(VPC Lattice Generated Domain) 자동 조회하여 env 파일 생성 ===
cat > /usr/local/bin/skills-lattice-client-refresh-env <<REFRESH
#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION}"
SERVICE_NAME="${SERVICE_NAME}"
SERVICE_URL=""

for _ in \$(seq 1 60); do
  SERVICE_DOMAIN=\$(aws vpc-lattice list-services \\
    --region "\$AWS_REGION" \\
    --query "items[?name=='\${SERVICE_NAME}'].dnsEntry.domainName | [0]" \\
    --output text 2>/dev/null || true)

  if [ -n "\$SERVICE_DOMAIN" ] && [ "\$SERVICE_DOMAIN" != "None" ]; then
    SERVICE_URL="http://\${SERVICE_DOMAIN}"
    break
  fi
  sleep 10
done

cat > /etc/skills-lattice-client.env <<EOF
SERVICE_URL=\${SERVICE_URL}
EOF
chmod 0644 /etc/skills-lattice-client.env

if [ -z "\$SERVICE_URL" ]; then
  echo "VPC Lattice Service domain not found for \${SERVICE_NAME}" >&2
  exit 1
fi
REFRESH
chmod 0755 /usr/local/bin/skills-lattice-client-refresh-env

# 초기 env 파일 (refresh 전 빈 값)
echo "SERVICE_URL=" > /etc/skills-lattice-client.env
chmod 0644 /etc/skills-lattice-client.env

cat > /etc/systemd/system/lattice-client-app.service <<'UNIT'
[Unit]
Description=Skills VPC Lattice Client App
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/skills-lattice-client.env
ExecStartPre=/usr/local/bin/skills-lattice-client-refresh-env
ExecStart=/usr/bin/python3 /opt/skills-lattice/client/client_app.py
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

# 서비스 기동 전에 SERVICE_URL을 미리 조회하여 env 파일을 채운다
# (systemd EnvironmentFile은 start 시점에 한 번만 읽히므로 ExecStartPre만으로는 부족)
/usr/local/bin/skills-lattice-client-refresh-env || true

systemctl daemon-reload
systemctl enable --now lattice-client-app.service
