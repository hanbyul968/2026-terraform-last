#!/bin/bash
# =============================================================================
# Module4 in-VPC Bastion bootstrap (self-contained, no external repo)
#  - k8s-apply.sh / app/module4(Dockerfile, worker.py, requirements.txt) 는
#    terraform 이 base64 로 인라인 주입한다. (GitHub clone 없음)
#  - 이 호스트가 EKS 클러스터에 대해 CoreDNS 패치 + KEDA/Karpenter 설치 +
#    worker 이미지 build/push + k8s 리소스 apply 를 자동 수행한다.
# =============================================================================
set -ex
exec > /var/log/skills-bastion-bootstrap.log 2>&1
export HOME=/root
export KUBECONFIG=/root/.kube/config
export PATH=$PATH:/usr/local/bin
REGION=us-west-2
CLUSTER=skills-sqs-cluster

dnf install -y docker git tar unzip
systemctl enable --now docker

# kubectl (클러스터 버전에 맞춰)
EKS_VER=$(aws eks describe-cluster --region $REGION --name $CLUSTER --query cluster.version --output text)
curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/v$${EKS_VER}.0/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# 클러스터가 ACTIVE 될 때까지 대기
until [ "$(aws eks describe-cluster --region $REGION --name $CLUSTER --query cluster.status --output text)" = "ACTIVE" ]; do sleep 15; done

# ---- 코드/앱 파일 인라인 배치 (git clone 대체) ----
mkdir -p /root/task2/app/module4
cd /root/task2

base64 -d <<'B64_APPLY' | gunzip > /root/task2/k8s-apply.sh
${k8s_apply_b64}
B64_APPLY
chmod +x /root/task2/k8s-apply.sh

base64 -d <<'B64_WORKER' | gunzip > /root/task2/app/module4/worker.py
${worker_b64}
B64_WORKER

base64 -d <<'B64_DOCKER' | gunzip > /root/task2/app/module4/Dockerfile
${dockerfile_b64}
B64_DOCKER

base64 -d <<'B64_REQS' | gunzip > /root/task2/app/module4/requirements.txt
${requirements_b64}
B64_REQS

# K8s 레이어 배포 (CoreDNS 패치 + KEDA/Karpenter + worker 이미지 build/push)
cd /root/task2
bash k8s-apply.sh
echo "BASTION_BOOTSTRAP_DONE"
