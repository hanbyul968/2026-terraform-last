#!/bin/bash
# unicorn-bastion userdata
# EKS 부트스트랩에 필요한 도구를 설치한다. (apply.sh 는 SSM 접속 후 수동 실행)
set -xe

dnf install -y docker git tar gzip unzip jq

# Docker
systemctl enable --now docker
usermod -aG docker ec2-user

# AWS CLI v2 (AL2023 기본 미포함)
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
cd /tmp && unzip -q awscliv2.zip && ./aws/install --update
cd /

# kubectl (EKS 1.35)
curl -sLO "https://dl.k8s.io/release/v1.35.0/bin/linux/amd64/kubectl"
install -m 0755 kubectl /usr/local/bin/kubectl
rm -f kubectl

# eksctl
curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /tmp
install -m 0755 /tmp/eksctl /usr/local/bin/eksctl

# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo "bastion tools ready" > /home/ec2-user/READY
chown ec2-user:ec2-user /home/ec2-user/READY
