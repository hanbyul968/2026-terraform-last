#!/bin/bash
# module2 analytics EC2 부트스트랩
#  - 주문 로그 앱(app.py, port 5000)을 /opt/app 에 배치하고 systemd 서비스 'app' 으로 등록
#  - rubric 2-5(/health), 2-3-B(/order), 2-6(systemctl is-active/is-enabled app) 대응
set -eux
exec > /var/log/module2-bootstrap.log 2>&1

dnf install -y python3 python3-pip
pip3 install --no-input boto3

mkdir -p /opt/app
cat > /opt/app/app.py <<'PYEOF'
${app_py}
PYEOF

cat > /etc/systemd/system/app.service <<'UNIT'
[Unit]
Description=wsc2026 order log application
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=STREAM_NAME=${stream}
Environment=AWS_REGION=${region}
ExecStart=/usr/bin/python3 /opt/app/app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now app
echo "MODULE2 BOOTSTRAP COMPLETE"
