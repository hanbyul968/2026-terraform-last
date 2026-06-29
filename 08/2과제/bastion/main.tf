# =============================================================================
# Bastion EC2 (배포 전용)
#  - 로컬 윈도우에서 이 폴더를 apply 하여 Bastion EC2를 먼저 생성한다.
#  - Bastion(Amazon Linux 2023)에 SSM Session Manager로 접속해 2과제 4개
#    모듈을 배포한다. (Bastion은 Linux 이므로 /bin/bash 의존 코드도 정상 동작)
#  - 접속: SSM Session Manager (키페어/22번 포트 불필요)
#  - 권한: 인스턴스 프로파일(AdministratorAccess) → IAM User AccessKey 미사용
#  - Region: ap-northeast-2 (Module1과 동일, 기본 VPC 사용으로 불필요 VPC 생성 방지)
# =============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"
}

# ---- 기본 VPC / 서브넷 (새 VPC를 만들지 않아 감점 방지) ----
# ---- Bastion 전용 VPC (이 계정엔 default VPC 가 없음) ----
resource "aws_vpc" "bn" {
  cidr_block           = "10.250.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "task-bastion-vpc" }
}
resource "aws_internet_gateway" "bn" {
  vpc_id = aws_vpc.bn.id
  tags   = { Name = "task-bastion-igw" }
}
resource "aws_subnet" "bn" {
  vpc_id                  = aws_vpc.bn.id
  cidr_block              = "10.250.0.0/24"
  map_public_ip_on_launch = true
  tags                    = { Name = "task-bastion-subnet" }
}
resource "aws_route_table" "bn" {
  vpc_id = aws_vpc.bn.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.bn.id
  }
  tags = { Name = "task-bastion-rt" }
}
resource "aws_route_table_association" "bn" {
  subnet_id      = aws_subnet.bn.id
  route_table_id = aws_route_table.bn.id
}

# ---- Amazon Linux 2023 최신 AMI ----
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---- IAM Role (SSM 접속 + 멀티리전 배포 권한) ----
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bastion" {
  name               = "bastion-deploy-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

# SSM Session Manager 접속용
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 2과제 4개 모듈(멀티 리전)을 배포하려면 광범위한 권한이 필요
resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "bastion-deploy-profile"
  role = aws_iam_role.bastion.name
}

# ---- Security Group (SSM만 사용하므로 인바운드 없음, 아웃바운드만 허용) ----
resource "aws_security_group" "bastion" {
  name        = "bastion-sg"
  description = "Bastion egress only (SSM Session Manager)"
  vpc_id      = aws_vpc.bn.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "bastion-sg"
  }
}

# ---- Bastion EC2 ----
resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.bn.id
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  associate_public_ip_address = true

  # 부팅 시 git / terraform 설치 (aws cli v2는 AL2023 기본 탑재)
  user_data = <<-EOF
    #!/bin/bash
    set -eux
    dnf install -y yum-utils git
    yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
    dnf install -y terraform
  EOF

  tags = {
    Name = "bastion"
  }
}

output "bastion_instance_id" {
  description = "Bastion EC2 인스턴스 ID"
  value       = aws_instance.bastion.id
}

output "ssm_connect_command" {
  description = "Bastion 접속 명령 (로컬 윈도우 PowerShell에서 실행)"
  value       = "aws ssm start-session --target ${aws_instance.bastion.id} --region ap-northeast-2"
}
