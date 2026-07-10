#!/bin/bash
# wsc2026-sensor-producer EC2 (SSM 세션) 에서 실행한다.
set -eux

BOOTSTRAP="<MSK IAM 부트스트랩 엔드포인트>"   # aws kafka get-bootstrap-brokers 의 BootstrapBrokerStringSaslIam

# --- Kafka CLI + IAM 인증 라이브러리 설치 ---
dnf install -y java-11-amazon-corretto-headless
cd /opt
curl -sL https://archive.apache.org/dist/kafka/3.6.0/kafka_2.13-3.6.0.tgz | tar xz
cd /opt/kafka_2.13-3.6.0/libs
curl -sLO https://github.com/aws/aws-msk-iam-auth/releases/download/v2.2.0/aws-msk-iam-auth-2.2.0-all.jar

cat >/opt/kafka_2.13-3.6.0/bin/client.properties <<'EOF'
security.protocol=SASL_SSL
sasl.mechanism=AWS_MSK_IAM
sasl.jaas.config=software.amazon.msk.auth.iam.IAMLoginModule required;
sasl.client.callback.handler.class=software.amazon.msk.auth.iam.IAMClientCallbackHandler
EOF

cd /opt/kafka_2.13-3.6.0

# --- Topic 생성 ---
bin/kafka-topics.sh --bootstrap-server "$BOOTSTRAP" --command-config bin/client.properties \
  --create --topic wsc2026-sensor-raw --partitions 3 --replication-factor 2

bin/kafka-topics.sh --bootstrap-server "$BOOTSTRAP" --command-config bin/client.properties \
  --create --topic wsc2026-sensor-alert --partitions 1 --replication-factor 2

# --- 확인 ---
bin/kafka-topics.sh --bootstrap-server "$BOOTSTRAP" --command-config bin/client.properties --describe
