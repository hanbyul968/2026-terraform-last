#!/bin/bash
# vf module4 Go producer bootstrap (MSK IAM)
set -euxo pipefail
exec > /var/log/module4-bootstrap.log 2>&1

REGION="${region}"
MSK_ARN="${msk_arn}"
APP_BUCKET="${app_bucket}"
APP_KEY="${app_key}"
SUPPORT_KEY="${support_key}"

mkdir -p /opt/app /opt/topic-admin
aws s3 cp "s3://$APP_BUCKET/$APP_KEY" /opt/app/app --region "$REGION"
aws s3 cp "s3://$APP_BUCKET/$SUPPORT_KEY" /tmp/topic-admin.zip --region "$REGION"
chmod 0755 /opt/app/app
python3 -m zipfile -e /tmp/topic-admin.zip /opt/topic-admin
# Lambda에는 boto3가 기본 제공되지만 EC2 Python에는 없으므로 signer 의존성을 설치한다.
dnf install -y python3-boto3 python3-pip
# kafka.sasl.oauth 를 제공하는 정확한 버전으로 고정한다.
# (미고정 시 kafka 3.0.10 등이 섞여 create_topics/iam_producer 가
#  ModuleNotFoundError: No module named 'kafka.sasl' 로 실패함 — Lambda 패키징과 동일 버전)
pip3 install --target /opt/topic-admin --upgrade "kafka-python==2.2.15" aws-msk-iam-sasl-signer-python

# Terraform waits for the MSK cluster, but retry bootstrap discovery for IAM/DNS propagation.
BOOTSTRAP=""
for i in $(seq 1 60); do
  BOOTSTRAP=$(aws kafka get-bootstrap-brokers \
    --cluster-arn "$MSK_ARN" \
    --region "$REGION" \
    --query 'BootstrapBrokerStringSaslIam' \
    --output text 2>/dev/null || true)
  [ -n "$BOOTSTRAP" ] && [ "$BOOTSTRAP" != "None" ] && break
  sleep 5
done
test -n "$BOOTSTRAP"
test "$BOOTSTRAP" != "None"

cat > /opt/app/create_topics.py <<'PY'
import sys

from aws_msk_iam_sasl_signer import MSKAuthTokenProvider
from kafka import KafkaAdminClient
from kafka.admin import NewTopic
from kafka.errors import TopicAlreadyExistsError
from kafka.sasl.oauth import AbstractTokenProvider

bootstrap_servers = sys.argv[1].split(",")
region = sys.argv[2]


class MSKTokenProvider(AbstractTokenProvider):
    def token(self):
        token, _ = MSKAuthTokenProvider.generate_auth_token(region)
        return token


admin = KafkaAdminClient(
    bootstrap_servers=bootstrap_servers,
    security_protocol="SASL_SSL",
    sasl_mechanism="OAUTHBEARER",
    sasl_oauth_token_provider=MSKTokenProvider(),
    client_id="wsc2026-topic-admin",
    request_timeout_ms=30000,
)

for topic in (
    NewTopic("wsc2026-sensor-raw", num_partitions=3, replication_factor=2),
    NewTopic("wsc2026-sensor-alert", num_partitions=1, replication_factor=2),
):
    try:
        admin.create_topics([topic], timeout_ms=30000)
        print(f"Created topic: {topic.name}")
    except TopicAlreadyExistsError:
        print(f"Topic already exists: {topic.name}")

admin.close()
PY

# Create the exact 3/2 and 1/2 topics without downloading the 108 MB Kafka distribution.
export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"
TOPICS_READY=false
for i in $(seq 1 30); do
  if PYTHONPATH=/opt/topic-admin python3 /opt/app/create_topics.py "$BOOTSTRAP" "$REGION"; then
    TOPICS_READY=true
    break
  fi
  sleep 5
done
test "$TOPICS_READY" = "true"

cat > /opt/app/iam_producer.py <<'PY'
import json
import os
import random
import time
from datetime import datetime, timedelta, timezone

from aws_msk_iam_sasl_signer import MSKAuthTokenProvider
from kafka import KafkaProducer
from kafka.sasl.oauth import AbstractTokenProvider

REGION = os.environ.get("AWS_REGION", "ap-northeast-1")
BOOTSTRAP_SERVERS = os.environ["BOOTSTRAP_SERVERS"]
TOPIC_RAW = os.environ.get("TOPIC_RAW", "wsc2026-sensor-raw")
KST = timezone(timedelta(hours=9))


class MSKTokenProvider(AbstractTokenProvider):
    def token(self):
        token, _ = MSKAuthTokenProvider.generate_auth_token(REGION)
        return token


producer = KafkaProducer(
    bootstrap_servers=BOOTSTRAP_SERVERS.split(","),
    security_protocol="SASL_SSL",
    sasl_mechanism="OAUTHBEARER",
    sasl_oauth_token_provider=MSKTokenProvider(),
    key_serializer=lambda value: value.encode("utf-8"),
    value_serializer=lambda value: json.dumps(value).encode("utf-8"),
    acks="all",
    retries=10,
)

sensors = (
    ("SENSOR-001", "factory-a", 75.0, 45.0),
    ("SENSOR-002", "factory-b", 68.0, 52.0),
    ("SENSOR-003", "factory-c", 82.0, 48.0),
)

while True:
    timestamp = datetime.now(KST).isoformat(timespec="seconds")
    for sensor_id, location, base_temp, base_humidity in sensors:
        record = {
            "sensorId": sensor_id,
            "timestamp": timestamp,
            "temperature": round(base_temp + random.uniform(-2.0, 2.0), 1),
            "humidity": round(base_humidity + random.uniform(-4.0, 4.0), 1),
            "location": location,
        }
        producer.send(TOPIC_RAW, key=sensor_id, value=record).get(timeout=30)
        print(json.dumps(record), flush=True)
    producer.flush()
    time.sleep(5)
PY

cat > /opt/app/producer.env <<ENV
BOOTSTRAP_SERVERS=$BOOTSTRAP
TOPIC_RAW=wsc2026-sensor-raw
AWS_REGION=$REGION
AWS_DEFAULT_REGION=$REGION
ENV

cat > /etc/systemd/system/producer.service <<'UNIT'
[Unit]
Description=wsc2026 vf MSK sensor producer
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/opt/app/producer.env
ExecStart=/opt/app/app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/producer-iam.service <<'UNIT'
[Unit]
Description=wsc2026 MSK IAM sensor producer companion
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/opt/app/producer.env
Environment=PYTHONPATH=/opt/topic-admin
ExecStart=/usr/bin/python3 /opt/app/iam_producer.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
# 제공된 Go 바이너리(/opt/app/app)는 이 MSK(SASL_SSL/IAM, 9098)에 TLS 없이 접속해 실패한다
# ("failed to publish sensor readings: unexpected EOF: broker appears to be expecting TLS").
# => producer.service 는 사용하지 않고, IAM 인증되는 Python producer-iam 만 실행한다.
systemctl disable --now producer 2>/dev/null || true
systemctl enable --now producer-iam
systemctl is-active producer-iam
echo "MODULE4 VF PRODUCER (IAM) READY"
