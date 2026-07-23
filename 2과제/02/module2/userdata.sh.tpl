#!/bin/bash
# vf module2 analytics application bootstrap
set -eux
exec > /var/log/module2-bootstrap.log 2>&1

dnf install -y python3 python3-pip

mkdir -p /opt/app
cat > /opt/app/app.py <<'PYEOF'
${app_py}
PYEOF
cat > /opt/app/requirements.txt <<'REQEOF'
${requirements}
REQEOF

pip3 install --no-input -r /opt/app/requirements.txt

cat > /etc/systemd/system/app.service <<'UNIT'
[Unit]
Description=wsc2026 order log application (Gunicorn)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/app
Environment=STREAM_NAME=${stream}
Environment=AWS_REGION=${region}
ExecStart=/usr/local/bin/gunicorn --bind 0.0.0.0:5000 --workers 2 app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now app
echo "MODULE2 VF APPLICATION BOOTSTRAP COMPLETE"
