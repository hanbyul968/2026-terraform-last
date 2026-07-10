#!/bin/bash
set -eux

dnf install -y python3.12 python3.12-pip

mkdir -p /opt/app
cd /opt/app

# app.py / requirements.txt 는 S3 또는 SSM 세션으로 업로드한다.
# aws s3 cp s3://<본인 임시버킷>/app.py /opt/app/app.py

python3.12 -m venv /opt/app/venv
/opt/app/venv/bin/pip install -r /opt/app/requirements.txt

cat >/etc/systemd/system/app.service <<'EOF'
[Unit]
Description=WSC2026 order log producer
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/app
Environment=STREAM_NAME=wsc2026-order-stream
Environment=AWS_REGION=ap-northeast-2
Environment=AWS_DEFAULT_REGION=ap-northeast-2
ExecStart=/opt/app/venv/bin/gunicorn -w 2 -b 0.0.0.0:5000 app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now app
