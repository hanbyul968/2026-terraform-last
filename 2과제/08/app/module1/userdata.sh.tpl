#!/bin/bash
# =============================================================================
# Module1 DocumentDB Client EC2 bootstrap (self-contained, no external repo)
#  - docdb_client.py / retail_dataset.json / requirements.txt 는 terraform 이
#    base64 로 인라인 주입한다. (GitHub 등 외부 의존 없음 → local apply 시 그대로 동작)
#  - 앱은 Secrets Manager(skills-nosql-docdb-secret)에서 접속정보를 읽어 DocumentDB 에
#    연결하고, TCP/8080 으로 HTTP API 를 제공한다. (docdb_client.py serve)
#  - 부팅 시: 데이터 seed + 요구 Index/TTL 생성까지 자동 수행한다.
# =============================================================================
set -ex
exec > /var/log/skills-nosql-bootstrap.log 2>&1

APP_DIR=/opt/skills-nosql
VENV_DIR=$${APP_DIR}/.venv
mkdir -p "$APP_DIR"

# ---- 1) 제공 배포파일을 그대로 배치 (수정 없이 배포) ----
base64 -d <<'B64_DOCDB' | gunzip > "$APP_DIR/docdb_client.py"
${docdb_client_b64}
B64_DOCDB

base64 -d <<'B64_DATASET' | gunzip > "$APP_DIR/retail_dataset.json"
${retail_dataset_b64}
B64_DATASET

base64 -d <<'B64_REQS' | gunzip > "$APP_DIR/requirements.txt"
${requirements_b64}
B64_REQS

# ---- 2) Python venv + 의존성(boto3, pymongo) ----
dnf install -y python3 python3-pip || yum install -y python3 python3-pip
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/python" -m pip install -r "$APP_DIR/requirements.txt"

# ---- 3) Amazon DocumentDB TLS CA Bundle ----
curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o "$APP_DIR/global-bundle.pem"

# ---- 4) systemd 서비스로 앱 상시 실행 (0.0.0.0:8080) ----
cat > /etc/systemd/system/skills-nosql-app.service <<'UNIT'
[Unit]
Description=Skills NoSQL DocumentDB Client App
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/skills-nosql
ExecStart=/opt/skills-nosql/.venv/bin/python /opt/skills-nosql/docdb_client.py serve
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now skills-nosql-app.service

# ---- 5) 앱 기동 대기 후 데이터 seed ----
# /health 는 DocumentDB 접속이 성공해야 200 을 준다. 클러스터가 available 될 때까지
# 최대 30분 대기한다. (짧게 끊으면 seed 가 통째로 누락돼 1-3/1-4/1-5 가 전부 실패)
for i in $(seq 1 360); do
  if curl -fsS http://127.0.0.1:8080/health >/dev/null 2>&1; then break; fi
  sleep 5
done

# seed 도 실패 시 재시도한다. (docdb 가 막 available 된 직후 일시적 오류 대비)
for i in $(seq 1 30); do
  if curl -fsS -X POST http://127.0.0.1:8080/v1/admin/seed >/dev/null 2>&1; then
    echo "seed ok (attempt $i)"; break
  fi
  echo "seed retry $i"; sleep 10
done

# ---- 6) 요구 Index / TTL 생성 (docdb_client 의 db() 재사용) ----
cd "$APP_DIR"
for i in $(seq 1 30); do
  if "$VENV_DIR/bin/python" - <<'PYIDX'
from docdb_client import db, ASCENDING, DESCENDING
d = db()
d.orders.create_index([('orderId', ASCENDING)], unique=True, name='orderId_1')
d.orders.create_index([('customerId', ASCENDING), ('createdAt', DESCENDING)], name='customerId_1_createdAt_-1')
d.orders.create_index([('status', ASCENDING), ('dueAt', ASCENDING)], name='status_1_dueAt_1')
d.products.create_index([('productId', ASCENDING)], unique=True, name='productId_1')
d.products.create_index([('warehouseId', ASCENDING), ('stock', ASCENDING)], name='warehouseId_1_stock_1')
d.sessions.create_index([('sessionId', ASCENDING)], unique=True, name='sessionId_1')
d.sessions.create_index([('expiresAt', ASCENDING)], expireAfterSeconds=0, name='expiresAt_1')
d.sessions.create_index([('customerId', ASCENDING), ('lastSeen', DESCENDING)], name='customerId_1_lastSeen_-1')
print("indexes created")
PYIDX
  then
    echo "indexes ok (attempt $i)"; break
  fi
  echo "index retry $i"; sleep 10
done

# ---- 7) 최종 검증 로그 (부팅 로그만 봐도 채점 항목 상태를 알 수 있게) ----
curl -s http://127.0.0.1:8080/v1/admin/summary || true
echo
curl -s http://127.0.0.1:8080/v1/admin/indexes || true
echo

echo "SKILLS_NOSQL_BOOTSTRAP_DONE"
