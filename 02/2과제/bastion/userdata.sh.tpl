#!/bin/bash
set -eux
exec > /var/log/bastion-bootstrap.log 2>&1
dnf install -y git docker yum-utils unzip tar jq
if ! command -v aws >/dev/null 2>&1; then
  curl -SL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -o /tmp/awscliv2.zip -d /tmp && /tmp/aws/install
fi
yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
dnf install -y terraform
systemctl enable --now docker
mkdir -p /opt/task2
aws s3 cp "s3://${bucket}/${key}" /tmp/task2.zip --region "${region}"
unzip -o /tmp/task2.zip -d /opt/task2
chmod +x /opt/task2/deploy.sh 2>/dev/null || true
chmod -R 777 /opt/task2
touch /opt/task2/READY
echo "BOOTSTRAP COMPLETE"
