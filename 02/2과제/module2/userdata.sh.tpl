#!/bin/bash
# module2 - 주문 로그 애플리케이션 부트스트랩
set -eux
exec > /var/log/app-bootstrap.log 2>&1

dnf install -y python3-pip
pip3 install boto3

mkdir -p /opt/app
base64 -d > /opt/app/app.py <<'B64'
${app_b64}
B64

cat > /etc/systemd/system/app.service <<UNIT
[Unit]
Description=Order Log Application
After=network.target

[Service]
Type=simple
Environment=STREAM_NAME=${stream_name}
Environment=AWS_REGION=${region}
ExecStart=/usr/bin/python3 /opt/app/app.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable app
systemctl start app
echo "APP BOOTSTRAP COMPLETE"
