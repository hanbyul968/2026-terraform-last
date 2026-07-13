#!/bin/bash
# module4 Producer EC2 부트스트랩 (MSK IAM 인증)
#  - 센서 데이터 producer 앱 배치(kafka-python + aws-msk-iam-sasl-signer)
#  - MSK ACTIVE 대기 → bootstrap brokers 조회 → 토픽 생성
#      wsc2026-sensor-raw(파티션3/복제2), wsc2026-sensor-alert(파티션1/복제2)
#  - systemd 서비스 'producer' 로 상시 실행 (rubric 4: Producer Running)
set -eux
exec > /var/log/module4-bootstrap.log 2>&1

REGION="${region}"
MSK_ARN="${msk_arn}"

dnf install -y java-17-amazon-corretto python3 python3-pip tar gzip
pip3 install --no-input kafka-python aws-msk-iam-sasl-signer-python

# ---- producer 앱 ----
mkdir -p /opt/app
cat > /opt/app/producer.py <<'PYEOF'
${producer_py}
PYEOF

# ---- Kafka CLI (토픽 생성용, IAM SASL) ----
KAFKA_VER=3.6.0
cd /opt
if [ ! -d "/opt/kafka" ]; then
  curl -SL "https://archive.apache.org/dist/kafka/$KAFKA_VER/kafka_2.13-$KAFKA_VER.tgz" -o /tmp/kafka.tgz
  tar -xzf /tmp/kafka.tgz -C /opt
  mv /opt/kafka_2.13-$KAFKA_VER /opt/kafka
fi
# MSK IAM Auth 클라이언트 라이브러리
curl -SL "https://github.com/aws/aws-msk-iam-auth/releases/download/v2.2.0/aws-msk-iam-auth-2.2.0-all.jar" \
  -o /opt/kafka/libs/aws-msk-iam-auth.jar || true
cat > /opt/kafka/config/client-iam.properties <<'PROP'
security.protocol=SASL_SSL
sasl.mechanism=AWS_MSK_IAM
sasl.jaas.config=software.amazon.msk.auth.iam.IAMLoginModule required;
sasl.client.callback.handler.class=software.amazon.msk.auth.iam.IAMClientCallbackHandler
PROP

# ---- setup.sh: MSK ACTIVE 대기 + bootstrap 조회 + 토픽 생성 + producer 기동 ----
cat > /opt/app/setup.sh <<SETUP
#!/bin/bash
set -eux
REGION="$REGION"
MSK_ARN="$MSK_ARN"
echo "MSK ACTIVE 대기..."
for i in \$(seq 1 90); do
  ST=\$(aws kafka describe-cluster --cluster-arn "\$MSK_ARN" --region "\$REGION" --query "ClusterInfo.State" --output text 2>/dev/null || true)
  echo "MSK state: \$ST"
  [ "\$ST" = "ACTIVE" ] && break
  sleep 20
done
BOOTSTRAP=\$(aws kafka get-bootstrap-brokers --cluster-arn "\$MSK_ARN" --region "\$REGION" --query "BootstrapBrokerStringSaslIam" --output text)
echo "BOOTSTRAP=\$BOOTSTRAP" > /opt/app/bootstrap.env
# 토픽 생성 (이미 있으면 무시)
/opt/kafka/bin/kafka-topics.sh --bootstrap-server "\$BOOTSTRAP" --command-config /opt/kafka/config/client-iam.properties \
  --create --if-not-exists --topic wsc2026-sensor-raw --partitions 3 --replication-factor 2 || true
/opt/kafka/bin/kafka-topics.sh --bootstrap-server "\$BOOTSTRAP" --command-config /opt/kafka/config/client-iam.properties \
  --create --if-not-exists --topic wsc2026-sensor-alert --partitions 1 --replication-factor 2 || true
systemctl daemon-reload
systemctl enable --now producer
echo "SETUP COMPLETE"
SETUP
chmod +x /opt/app/setup.sh

# ---- producer systemd 서비스 ----
cat > /etc/systemd/system/producer.service <<'UNIT'
[Unit]
Description=wsc2026 MSK sensor producer
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/opt/app/bootstrap.env
Environment=AWS_REGION=REGION_PLACEHOLDER
ExecStart=/usr/bin/python3 /opt/app/producer.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
sed -i "s/REGION_PLACEHOLDER/$REGION/" /etc/systemd/system/producer.service
systemctl daemon-reload

# MSK 가 준비되는 데 시간이 걸리므로 setup 은 백그라운드로 진행(부트스트랩 조회/토픽 생성/기동).
nohup /opt/app/setup.sh >/var/log/module4-setup.log 2>&1 &
echo "MODULE4 BOOTSTRAP COMPLETE"
