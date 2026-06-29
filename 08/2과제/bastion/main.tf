# =============================================================================
# Bastion EC2 (ë°°í¬ ?„ìš©)
#  - ë¡œì»¬ ?ˆë„?°ì—?????´ë”ë¥?apply ?˜ì—¬ Bastion EC2ë¥?ë¨¼ì? ?ì„±?œë‹¤.
#  - Bastion(Amazon Linux 2023)??SSM Session Managerë¡??‘ì†??2ê³¼ì œ 4ê°?#    ëª¨ë“ˆ??ë°°í¬?œë‹¤. (Bastion?€ Linux ?´ë?ë¡?/bin/bash ?˜ì¡´ ì½”ë“œ???•ìƒ ?™ì‘)
#  - ?‘ì†: SSM Session Manager (?¤í˜??22ë²??¬íŠ¸ ë¶ˆí•„??
#  - ê¶Œí•œ: ?¸ìŠ¤?´ìŠ¤ ?„ë¡œ?Œì¼(AdministratorAccess) ??IAM User AccessKey ë¯¸ì‚¬??#  - Region: ap-northeast-2 (Module1ê³??™ì¼, ê¸°ë³¸ VPC ?¬ìš©?¼ë¡œ ë¶ˆí•„??VPC ?ì„± ë°©ì?)
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

# ---- ê¸°ë³¸ VPC / ?œë¸Œ??(??VPCë¥?ë§Œë“¤ì§€ ?Šì•„ ê°ì  ë°©ì?) ----
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ---- Amazon Linux 2023 ìµœì‹  AMI ----
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

# ---- IAM Role (SSM ?‘ì† + ë©€?°ë¦¬??ë°°í¬ ê¶Œí•œ) ----
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

# SSM Session Manager ?‘ì†??resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 2ê³¼ì œ 4ê°?ëª¨ë“ˆ(ë©€??ë¦¬ì „)??ë°°í¬?˜ë ¤ë©?ê´‘ë²”?„í•œ ê¶Œí•œ???„ìš”
resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "bastion-deploy-profile"
  role = aws_iam_role.bastion.name
}

# ---- Security Group (SSMë§??¬ìš©?˜ë?ë¡??¸ë°”?´ë“œ ?†ìŒ, ?„ì›ƒë°”ìš´?œë§Œ ?ˆìš©) ----
resource "aws_security_group" "bastion" {
  name        = "bastion-sg"
  description = "Bastion egress only (SSM Session Manager)"
  vpc_id      = data.aws_vpc.default.id

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
  subnet_id                   = data.aws_subnets.default.ids[0]
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  associate_public_ip_address = true

  # ë¶€????git / terraform ?¤ì¹˜ (aws cli v2??AL2023 ê¸°ë³¸ ?‘ì¬)
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
  description = "Bastion EC2 ?¸ìŠ¤?´ìŠ¤ ID"
  value       = aws_instance.bastion.id
}

output "ssm_connect_command" {
  description = "Bastion ?‘ì† ëª…ë ¹ (ë¡œì»¬ ?ˆë„??PowerShell?ì„œ ?¤í–‰)"
  value       = "aws ssm start-session --target ${aws_instance.bastion.id} --region ap-northeast-2"
}
