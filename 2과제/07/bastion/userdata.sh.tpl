#!/bin/bash
# =============================================================================
# Bastion 부트스트랩 (cloud-init user_data) — 회복력 강화판
#  - 핵심 순서: 필수도구(aws/terraform) + 코드 번들 을 "먼저" 준비하고 READY 마커 생성.
#    helm/docker/kubectl 은 이후 best-effort(실패해도 부트스트랩을 죽이지 않음).
#    => get.helm.sh 같은 외부 다운로드 하나가 실패해도 /opt/task2 코드와 terraform 은
#       항상 준비되어 destroy/apply(module1·2) 가 가능하다.
#  - set -e 제거: 개별 다운로드 실패가 전체를 중단시키지 않도록. 대신 필수 단계는
#    명시적으로 검사해 READY 조건을 만든다.
#  - 모든 curl 에 --max-time + 재시도(for 루프) 적용.
#  - 로그: /var/log/bastion-bootstrap.log
#  - 완료 마커: /opt/task2/READY
# =============================================================================
set -ux
exec > /var/log/bastion-bootstrap.log 2>&1

# ---- 1) 기본 도구 ----
dnf install -y git docker yum-utils unzip tar jq || dnf install -y git docker yum-utils unzip tar jq

# ---- 2) AWS CLI v2 (AL2023 기본 포함, 없을 경우 대비) ----
if ! command -v aws >/dev/null 2>&1; then
  for _ in 1 2 3; do
    curl -SL --max-time 180 "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip && break
    sleep 5
  done
  unzip -o /tmp/awscliv2.zip -d /tmp && /tmp/aws/install
fi

# ---- 3) terraform ----
yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
dnf install -y terraform || dnf install -y terraform

# =============================================================================
# 4) 코드 번들 — helm/docker 보다 "먼저" 받는다.
#    (도구 설치가 실패해도 모듈 코드와 terraform 은 항상 존재하도록)
# =============================================================================
mkdir -p /opt/task2
for _ in 1 2 3 4 5; do
  aws s3 cp "s3://${bucket}/${bundle_key}" /tmp/task2.zip --region "${region}" && break
  echo "[retry] bundle download"; sleep 5
done
unzip -o /tmp/task2.zip -d /opt/task2

for _ in 1 2 3 4 5; do
  aws s3 cp "s3://${bucket}/${deploy_key}" /opt/task2/deploy.sh --region "${region}" && break
  echo "[retry] deploy.sh download"; sleep 5
done

echo "${competitor_number}" > /opt/task2/.competitor_number
chmod +x /opt/task2/deploy.sh 2>/dev/null || true
chmod +x /opt/task2/module3/deploy_k8s.sh 2>/dev/null || true
chmod +x /opt/task2/module3/deploy.sh 2>/dev/null || true
chmod +x /opt/task2/module4/manifest/setup.sh 2>/dev/null || true
chmod -R 777 /opt/task2

# ---- 필수 조건 검사 후 READY (helm/docker 실패와 무관하게 배포 가능) ----
if command -v terraform >/dev/null 2>&1 && command -v aws >/dev/null 2>&1 && [ -d /opt/task2/module1 ]; then
  touch /opt/task2/READY
  echo "CORE READY: terraform+aws+bundle 준비 완료 (아래 도구는 best-effort)"
else
  echo "CORE FAILED: terraform/aws/bundle 중 일부 미준비 — 로그 확인 필요"
fi

# =============================================================================
# 5) 이하 도구는 best-effort (실패해도 부트스트랩/READY 에 영향 없음)
#    module3/4 의 helm·docker 단계에서 필요. 실패 시 deploy.sh 가 재시도/안내.
# =============================================================================

# ---- kubectl (EKS 1.35) ----
for _ in 1 2 3; do
  curl -sLo /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -sL --max-time 30 https://dl.k8s.io/release/stable-1.35.txt)/bin/linux/amd64/kubectl" && break
  sleep 5
done
chmod +x /usr/local/bin/kubectl 2>/dev/null || true

# ---- helm (get.helm.sh 불안정 대비: 재시도 + 실패해도 계속) ----
for _ in 1 2 3 4 5; do
  curl -fsSL --max-time 120 "https://get.helm.sh/helm-v3.16.4-linux-amd64.tar.gz" -o /tmp/helm.tgz && break
  echo "[retry] helm download"; sleep 10
done
( tar -xzf /tmp/helm.tgz -C /tmp && install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm ) \
  || echo "WARN: helm 설치 실패 — module3/4 배포 전 'curl -fsSL https://get.helm.sh/... | tar' 로 수동 설치 필요"

# ---- docker + buildx ----
systemctl enable --now docker || true
usermod -aG docker ec2-user || true
chmod 666 /var/run/docker.sock || true
mkdir -p /usr/libexec/docker/cli-plugins
for _ in 1 2 3; do
  curl -SL --max-time 120 "https://github.com/docker/buildx/releases/download/v0.17.1/buildx-v0.17.1.linux-amd64" \
    -o /usr/libexec/docker/cli-plugins/docker-buildx && break
  sleep 5
done
chmod +x /usr/libexec/docker/cli-plugins/docker-buildx 2>/dev/null || true

echo "BOOTSTRAP COMPLETE (all best-effort tools attempted)"
