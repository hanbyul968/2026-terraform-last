#!/bin/bash
# module4 - Producer EC2 부트스트랩
#   1) Kafka CLI(IAM) 로 토픽 생성: wsc2026-sensor-raw(3,2), wsc2026-sensor-alert(1,2)
#   2) python producer 를 systemd 서비스(sensor-producer)로 상시 실행
set -ux
exec > /var/log/producer-bootstrap.log 2>&1

REGION="${region}"
CLUSTER_ARN="${cluster_arn}"

dnf install -y java-17-amazon-corretto python3-pip tar
pip3 install kafka-python aws-msk-iam-sasl-signer-python boto3

# ---- producer 앱 배치 ----
mkdir -p /opt/producer
base64 -d > /opt/producer/producer.py <<'B64'
${app_b64}
B64

# ---- Kafka 클라이언트(토픽 생성용) + IAM auth jar ----
cd /opt
KAFKA_VERSION="3.6.0"
SCALA="2.13"
KT="kafka_$${SCALA}-$${KAFKA_VERSION}.tgz"
curl -fsSL --retry 3 -o "$KT" "https://archive.apache.org/dist/kafka/$${KAFKA_VERSION}/$KT" && tar -xzf "$KT" && ln -s "kafka_$${SCALA}-$${KAFKA_VERSION}" kafka
curl -fsSL --retry 3 -o /opt/kafka/libs/aws-msk-iam-auth.jar \
  "https://github.com/aws/aws-msk-iam-auth/releases/download/v2.2.0/aws-msk-iam-auth-2.2.0-all.jar" || true

cat > /opt/kafka/config/client-iam.properties <<PROP
security.protocol=SASL_SSL
sasl.mechanism=AWS_MSK_IAM
sasl.jaas.config=software.amazon.msk.auth.iam.IAMLoginModule required;
sasl.client.callback.handler.class=software.amazon.msk.auth.iam.IAMClientCallbackHandler
PROP

# ---- bootstrap brokers(IAM) 조회 ----
BOOT=$(aws kafka get-bootstrap-brokers --cluster-arn "$CLUSTER_ARN" --region "$REGION" \
  --query "BootstrapBrokerStringSaslIam" --output text)
echo "BOOTSTRAP=$BOOT"

# ---- 토픽 생성 (이미 있으면 무시) ----
/opt/kafka/bin/kafka-topics.sh --bootstrap-server "$BOOT" --command-config /opt/kafka/config/client-iam.properties \
  --create --topic wsc2026-sensor-raw --partitions 3 --replication-factor 2 || true
/opt/kafka/bin/kafka-topics.sh --bootstrap-server "$BOOT" --command-config /opt/kafka/config/client-iam.properties \
  --create --topic wsc2026-sensor-alert --partitions 1 --replication-factor 2 || true

# ---- producer systemd 서비스 ----
cat > /etc/systemd/system/sensor-producer.service <<UNIT
[Unit]
Description=MSK Sensor Producer
After=network.target

[Service]
Type=simple
Environment=BOOTSTRAP=$BOOT
Environment=AWS_REGION=$REGION
ExecStart=/usr/bin/python3 /opt/producer/producer.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable sensor-producer
systemctl start sensor-producer
echo "PRODUCER BOOTSTRAP COMPLETE"
