###############################################################################
# 1?�계 (로컬?�서 ?�행) - ?�트?�크 기반 + Bastion + 코드 배포??S3
#   - VPC(?�브??IGW/?�우??VPC Endpoint ?�함) ?�성
#   - Bastion EC2 (Administrator 권한, Password ?�증, EIP 고정)
#       ??user_data ?�서 awscli/kubectl/eksctl/terraform/git ?�치
#       ??2?�계 코드(app/, modules/, manifest/, 배포?�일/)�?S3?�서 ?�동 ?�운로드
#   - 2?�계 코드�??�을 코드 버킷 ?�성 �??�로??#
# ?�행 ??Bastion ??SSH ?�속?�여 ~/project/app ?�서 `terraform apply` �?2?�계 진행.
###############################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"
}

# ========== VPC ==========
module "VPC" {
  source                = "../modules/VPC"
  vpc_name              = "worldpay-vpc"
  vpc_cidr              = "10.0.0.0/16"
  public_subnets_cidr   = ["10.0.0.0/24", "10.0.1.0/24"]
  isolated_subnets_cidr = ["10.0.2.0/24", "10.0.3.0/24"]
  availability_zones    = ["ap-northeast-2a", "ap-northeast-2c"]
  public_subnet_names   = ["worldpay-public-subnet-a", "worldpay-public-subnet-c"]
  isolated_subnet_names = ["worldpay-isolated-subnet-a", "worldpay-isolated-subnet-c"]
}

# ========== 코드 배포??S3 버킷 ==========
# 2?�계(app) 코드�?Bastion ?�로 ?�달?�기 ?�한 버킷
resource "aws_s3_bucket" "code" {
  bucket_prefix = "worldpay-code-"
  force_destroy = true
}

# app/*.tf
resource "aws_s3_object" "app" {
  for_each = fileset("${path.root}/../app", "*.tf")
  bucket   = aws_s3_bucket.code.id
  key      = "app/${each.value}"
  source   = "${path.root}/../app/${each.value}"
  etag     = filemd5("${path.root}/../app/${each.value}")
}

# modules/**/*.tf
resource "aws_s3_object" "modules" {
  for_each = fileset("${path.root}/../modules", "**/*.tf")
  bucket   = aws_s3_bucket.code.id
  key      = "modules/${each.value}"
  source   = "${path.root}/../modules/${each.value}"
  etag     = filemd5("${path.root}/../modules/${each.value}")
}

# manifest/*
resource "aws_s3_object" "manifest" {
  for_each = fileset("${path.root}/../manifest", "*")
  bucket   = aws_s3_bucket.code.id
  key      = "manifest/${each.value}"
  source   = "${path.root}/../manifest/${each.value}"
  etag     = filemd5("${path.root}/../manifest/${each.value}")
}

# 배포?�일/*
resource "aws_s3_object" "dist" {
  for_each = fileset("${path.root}/../배포?�일", "*")
  bucket   = aws_s3_bucket.code.id
  key      = "배포?�일/${each.value}"
  source   = "${path.root}/../배포?�일/${each.value}"
  etag     = filemd5("${path.root}/../배포?�일/${each.value}")
}

# ========== Bastion ==========
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_eip" "bastion" {
  domain = "vpc"
  tags   = { Name = "worldpay-bastion-eip" }
}

resource "aws_iam_role" "bastion" {
  name = "worldpay-bastion-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "worldpay-bastion-profile"
  role = aws_iam_role.bastion.name
}

resource "aws_security_group" "bastion" {
  name   = "worldpay-bastion-sg"
  vpc_id = module.VPC.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "worldpay-bastion-sg" }
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.small"
  subnet_id              = module.VPC.public_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.bastion.id]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name

  # 2?�계 코드가 S3??모두 ?�라???�에 부?�하?�록 보장
  depends_on = [
    aws_s3_object.app,
    aws_s3_object.modules,
    aws_s3_object.manifest,
    aws_s3_object.dist,
  ]

  user_data = <<-EOF
    #!/bin/bash
    # ===== Password ?�증 =====
    echo 'ec2-user:worldpay2026!' | chpasswd
    sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
    systemctl restart sshd

    # ===== 기본 ?�키지 =====
    yum install -y curl jq unzip git

    # awscliv2
    curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -qo /tmp/awscliv2.zip -d /tmp && /tmp/aws/install --update

    # kubectl
    curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

    # eksctl
    curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /usr/local/bin

    # terraform (2?�계 apply ??
    curl -sLo /tmp/terraform.zip "https://releases.hashicorp.com/terraform/1.13.4/terraform_1.13.4_linux_amd64.zip"
    unzip -qo /tmp/terraform.zip -d /usr/local/bin
    chmod +x /usr/local/bin/terraform

    # ===== 2?�계 코드 ?�운로드 =====
    mkdir -p /home/ec2-user/project
    aws s3 cp s3://${aws_s3_bucket.code.id}/ /home/ec2-user/project --recursive --region ap-northeast-2
    chown -R ec2-user:ec2-user /home/ec2-user/project
    echo "${aws_s3_bucket.code.id}" > /home/ec2-user/CODE_BUCKET.txt
    chown ec2-user:ec2-user /home/ec2-user/CODE_BUCKET.txt
  EOF

  tags = { Name = "worldpay-bastion" }
}

resource "aws_eip_association" "bastion" {
  instance_id   = aws_instance.bastion.id
  allocation_id = aws_eip.bastion.id
}
