#!/bin/bash
# =============================================================================
# 통합 Bastion 부트스트랩 (cloud-init user_data)
#  - 목적: (1) 과제 5 채점용 SSH 비번 로그인 활성화 + kubectl/eksctl/sshpass 준비
#          (2) SSH/SSM 접속 후 바로 root terraform apply 가 가능하도록 모든 것을 자동 준비
#  - 흐름: SSH 비번 설정 → 도구 설치 → S3에서 1과제 코드 번들 다운로드/해제 → runner 생성
#  - 로그: /var/log/bastion-bootstrap.log
#  - 완료 마커: /opt/task1/READY  (이 파일이 보이면 준비 완료)
# =============================================================================
set -eux
exec > /var/log/bastion-bootstrap.log 2>&1

# ---- 0) SSH Password 인증 활성화 + ec2-user 비밀번호 설정 (과제 5) ----
echo "ec2-user:${ssh_password}" | chpasswd
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
# AL2023 는 drop-in 으로 password auth 를 끄므로 덮어쓴다
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/50-wsc.conf <<EOF
PasswordAuthentication yes
PermitRootLogin no
EOF
systemctl restart sshd || true

# 기본 리전 설정 (ec2-user)
mkdir -p /home/ec2-user/.aws
cat > /home/ec2-user/.aws/config <<EOF
[default]
region = ${region}
output = json
EOF
chown -R ec2-user:ec2-user /home/ec2-user/.aws

# ---- 1) 기본 도구 ----
dnf install -y git docker yum-utils unzip tar jq iputils gzip

# AWS CLI v2 (AL2023 기본 포함, 없을 경우 대비)
if ! command -v aws >/dev/null 2>&1; then
  curl -SL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -o /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
fi

# sshpass (채점에서 노드/배스천 접속 시 사용)
dnf install -y sshpass || true

# ---- 2) terraform ----
yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
dnf install -y terraform

# ---- 3) kubectl (k8s/helm provider 인증 디버깅용; 적용 자체는 provider 가 수행) ----
curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
ln -sf /usr/local/bin/kubectl /usr/bin/kubectl

# ---- 3b) eksctl ----
curl -fsSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /tmp
mv /tmp/eksctl /usr/local/bin/eksctl
chmod +x /usr/local/bin/eksctl
ln -sf /usr/local/bin/eksctl /usr/bin/eksctl

# ---- 4) docker + buildx (root ecr.tf 가 docker build 사용) ----
systemctl enable --now docker
usermod -aG docker ec2-user || true
# SSM 접속 사용자(ssm-user)가 부팅 시점에 아직 없을 수 있어, 임시로 docker 소켓을 개방한다.
chmod 666 /var/run/docker.sock || true

mkdir -p /usr/libexec/docker/cli-plugins
curl -SL https://github.com/docker/buildx/releases/download/v0.17.1/buildx-v0.17.1.linux-amd64 \
  -o /usr/libexec/docker/cli-plugins/docker-buildx
chmod +x /usr/libexec/docker/cli-plugins/docker-buildx

# ---- 5) 1과제 코드 번들 받기 (terraform 이 로컬 현재 파일을 S3 로 업로드해 둠) ----
mkdir -p /opt/task1
aws s3 cp "s3://${bucket}/${key}" /tmp/task1.zip --region "${region}"
unzip -o /tmp/task1.zip -d /opt/task1

# ---- CRLF 정규화 ----
# Windows 에서 zip 된 .tf/스크립트가 CRLF 일 수 있어, Linux 에서 실행 시 에러가 난다.
find /opt/task1 -type f \( -name '*.tf' -o -name '*.sh' -o -name 'Dockerfile' -o -name '*.tpl' -o -name '*.tftpl' -o -name '*.json' -o -name '*.js' -o -name '*.yaml' -o -name '*.yml' \) -exec sed -i 's/\r$//' {} + || true

# 지급 바이너리 실행 권한 + 누구나 작업 가능하도록 권한 개방(임시 bastion)
chmod +x /opt/task1/files/book || true
chmod -R 777 /opt/task1

# kubeconfig (ec2-user) — 클러스터가 아직 없으면 실패해도 무시
sudo -u ec2-user aws eks update-kubeconfig --region ${region} --name ${cluster_name} || true

# ---- 6) 원클릭 실행 스크립트 ----
cat > /opt/task1/run.sh <<'RUN'
#!/bin/bash
set -e
cd /opt/task1
terraform init -input=false
# 1단계 (AWS 레이어): 노드 부팅용 임시 NAT egress 켜고 root 인프라(+노드그룹) 생성.
#   fully-private 노드가 최초 ECR 이미지 pull 을 제때 끝내 노드그룹이 ACTIVE 되도록 함.
terraform apply -auto-approve -var="bootstrap_egress=true"
# 2단계 (k8s/helm): book/LB Controller/kube-prometheus-stack/TGB + EKS finalize (egress 켜둔 채)
cd /opt/task1/k8s
terraform init -input=false
terraform apply -auto-approve
# 3단계: 임시 egress 제거 → workload 라우팅 0 복구(채점 1-1-C). 노드는 이미 Ready 라 유지됨.
cd /opt/task1
terraform apply -auto-approve -var="bootstrap_egress=false"
echo ""
echo "================= OUTPUTS ================="
terraform output || true
RUN
chmod +x /opt/task1/run.sh

# ---- 7) 완료 마커 ----
touch /opt/task1/READY
echo "BOOTSTRAP COMPLETE"
