#!/bin/bash
# =============================================================================
# Module 3 EC2 bootstrap (wsc-log-app-bastion) — user_data 가 호출.
#   env: BUCKET, SSM_PARAM, REGION, CLUSTER, NM(비번호)
#   1) Docker 설치 → 배포파일(app/) 다운로드 → 이미지 빌드 → 컨테이너 실행
#      (--restart always, 기본 json-file 로깅 드라이버, 컨테이너명 wsc-log-app, 5000)
#   2) kubectl/helm 설치 + EKS 접속 → setup.sh 실행(Loki/Grafana 배포, Loki NLB→SSM)
#   3) Fluent Bit 호스트 설치(systemd). record_modifier 로 namespace=wsc-app-log 추가
#      → Loki NLB(:3100) 로 전송.
#   ※ 이 호스트는 EKS cluster-admin access entry 를 가지므로 mark3.sh(kubectl) 채점도 가능.
# =============================================================================
exec > /var/log/ec2-bootstrap.log 2>&1
set -x

: "${BUCKET:?}"; : "${SSM_PARAM:?}"; : "${REGION:=ap-northeast-1}"
: "${CLUSTER:=wsc-logging-cluster}"; : "${NM:=00}"
export TZ=Asia/Seoul

# ── 1) Docker + flask 앱 ──────────────────────────────────────────────────────
dnf install -y docker git tar unzip jq || yum install -y docker git tar unzip jq
systemctl enable --now docker

mkdir -p /opt/app
aws s3 cp "s3://$BUCKET/app/app.py" /opt/app/app.py --region "$REGION"
aws s3 cp "s3://$BUCKET/app/requirements.txt" /opt/app/requirements.txt --region "$REGION"
aws s3 cp "s3://$BUCKET/app/Dockerfile" /opt/app/Dockerfile --region "$REGION"

cd /opt/app
docker build -t wsc-log-app:latest .
docker rm -f wsc-log-app 2>/dev/null || true
# 기본 json-file 드라이버 / 항상 재시작 / Asia/Seoul
docker run -d --name wsc-log-app --restart always \
  -e TZ=Asia/Seoul \
  -p 5000:5000 \
  --log-driver json-file \
  wsc-log-app:latest

# ── 2) kubectl/helm + setup.sh (Loki/Grafana) ────────────────────────────────
curl -sLO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
sudo -u ec2-user bash -c "aws eks update-kubeconfig --name $CLUSTER --region $REGION" || true

aws s3 cp "s3://$BUCKET/setup.sh" /opt/setup.sh --region "$REGION"
chmod +x /opt/setup.sh
bash /opt/setup.sh "$NM"

# ── 3) Fluent Bit (host, systemd) ─────────────────────────────────────────────
cat > /etc/yum.repos.d/fluent-bit.repo <<'REPO'
[fluent-bit]
name=Fluent Bit
baseurl=https://packages.fluentbit.io/amazonlinux/2023/
gpgcheck=1
gpgkey=https://packages.fluentbit.io/fluentbit.key
enabled=1
REPO
dnf install -y fluent-bit || yum install -y fluent-bit

# Loki 엔드포인트(SSM, setup.sh 가 기록) 확정 대기
for i in $(seq 1 60); do
  LOKI_HOST=$(aws ssm get-parameter --name "$SSM_PARAM" --region "$REGION" \
    --query 'Parameter.Value' --output text 2>/dev/null)
  [ -n "$LOKI_HOST" ] && [ "$LOKI_HOST" != "pending" ] && break
  sleep 15
done

mkdir -p /etc/fluent-bit
cat > /etc/fluent-bit/parsers.conf <<'PARSER'
[PARSER]
    Name        docker
    Format      json
    Time_Key    time
    Time_Format %Y-%m-%dT%H:%M:%S.%L
    Time_Keep   On
PARSER

cat > /etc/fluent-bit/fluent-bit.conf <<CONF
[SERVICE]
    Flush        1
    Daemon       Off
    Log_Level    info
    Parsers_File parsers.conf

[INPUT]
    Name              tail
    Tag               docker.*
    Path              /var/lib/docker/containers/*/*.log
    Parser            docker
    Refresh_Interval  5
    Mem_Buf_Limit     10MB

# record_modifier 로 namespace 레이블 값 추가 (= wsc-app-log)
[FILTER]
    Name          record_modifier
    Match         *
    Record        namespace wsc-app-log

[OUTPUT]
    Name          loki
    Match         *
    Host          ${LOKI_HOST}
    Port          3100
    Labels        job=fluent-bit
    Label_keys    \$namespace
    Line_format   json
    Auto_kubernetes_labels off
CONF

systemctl enable fluent-bit
systemctl restart fluent-bit

echo "ec2-bootstrap done (loki=$LOKI_HOST)" > /opt/ec2_ready.txt
