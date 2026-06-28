# =============================================================================
# Bastion EC2 (배포 작업용)
#  - 목적: Windows 로컬 대신, 이 EC2에 SSM으로 접속해 main terraform apply
#          + docker build/push 를 수행한다.
#  - 접속: SSM Session Manager (SSH 키/인바운드 불필요)
#  - 권한: 인스턴스 프로파일(AdministratorAccess)로 terraform이 자격증명 자동 사용
#
# ※ 이 폴더(state)는 main과 분리되어 있다. 채점 전 이 폴더에서만
#   `terraform destroy` 하면 Bastion만 제거되어 8-2(불필요 리소스) 감점을 피한다.
# =============================================================================

# ---- 기본 VPC / 서브넷 사용 (main VPC와 무관) ----
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ---- 최신 Amazon Linux 2023 AMI ----
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ---- IAM Role + Instance Profile (SSM + 배포 권한) ----
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bastion" {
  name               = "${var.player_id}-bastion-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# SSM 접속용
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# terraform이 모든 리소스를 생성할 수 있도록 (대회 계정 한정 사용)
resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.player_id}-bastion-profile"
  role = aws_iam_role.bastion.name
}

# ---- 보안 그룹: 인바운드 0개 (SSM은 아웃바운드 443만 사용) ----
resource "aws_security_group" "bastion" {
  name        = "${var.player_id}-bastion-sg"
  description = "Bastion SG - no inbound, SSM via outbound 443 only"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "All outbound (SSM, ECR, docker pull, etc)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.player_id}-bastion-sg"
  }
}

# ---- user_data: terraform / docker / buildx / git 설치 ----
locals {
  user_data = <<-EOT
    #!/bin/bash
    set -eux

    # 기본 도구
    dnf install -y git docker yum-utils

    # terraform
    yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
    dnf install -y terraform

    # docker 시작 + 권한
    systemctl enable --now docker
    usermod -aG docker ec2-user
    usermod -aG docker ssm-user || true

    # docker buildx 플러그인 (main ecr.tf가 buildx 사용)
    mkdir -p /usr/libexec/docker/cli-plugins
    curl -SL https://github.com/docker/buildx/releases/download/v0.17.1/buildx-v0.17.1.linux-amd64 \
      -o /usr/libexec/docker/cli-plugins/docker-buildx
    chmod +x /usr/libexec/docker/cli-plugins/docker-buildx
  EOT
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = tolist(data.aws_subnets.default.ids)[0]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids = [aws_security_group.bastion.id]
  user_data              = local.user_data

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = {
    Name = "${var.player_id}-bastion"
  }
}
