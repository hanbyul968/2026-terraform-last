#!/bin/bash
set -eux
exec > /var/log/bastion-bootstrap.log 2>&1

# ---- tools ----
dnf install -y git docker yum-utils unzip tar jq
if ! command -v aws >/dev/null 2>&1; then
  curl -SL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -o /tmp/awscliv2.zip -d /tmp && /tmp/aws/install
fi
yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
dnf install -y terraform
systemctl enable --now docker
usermod -aG docker ec2-user || true
chmod 666 /var/run/docker.sock || true
mkdir -p /usr/libexec/docker/cli-plugins
curl -SL https://github.com/docker/buildx/releases/download/v0.17.1/buildx-v0.17.1.linux-amd64 \
  -o /usr/libexec/docker/cli-plugins/docker-buildx && chmod +x /usr/libexec/docker/cli-plugins/docker-buildx
# kubectl
curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash || true

# ---- download 2과제 bundle ----
mkdir -p /opt/task2
aws s3 cp "s3://${bucket}/${key}" /tmp/task2.zip --region "${region}"
unzip -o /tmp/task2.zip -d /opt/task2
chmod +x /opt/task2/deploy.sh 2>/dev/null || true
chmod -R 777 /opt/task2
touch /opt/task2/READY
echo "BOOTSTRAP COMPLETE"
