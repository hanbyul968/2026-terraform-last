# 2과제(02) 배포용 Bastion — 로컬 PowerShell 에서 apply → SSM → bash /opt/task2/deploy.sh
data "aws_caller_identity" "current" {}
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

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

data "archive_file" "task2" {
  type        = "zip"
  source_dir  = "${path.module}/.."
  output_path = "${path.module}/../../.task2_bundle_02.zip"
  excludes = [
    "bastion", "bastion/**",
    "**/.terraform", "**/.terraform/**",
    "**/terraform.tfstate", "**/terraform.tfstate.*",
    "**/.terraform.lock.hcl", "**/*.tfplan",
  ]
}

resource "aws_s3_bucket" "bootstrap" {
  bucket        = "${var.player_id}-task2-02-bootstrap-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}
resource "aws_s3_bucket_public_access_block" "bootstrap" {
  bucket                  = aws_s3_bucket.bootstrap.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_object" "bundle" {
  bucket = aws_s3_bucket.bootstrap.id
  key    = "task2-bundle.zip"
  source = data.archive_file.task2.output_path
  etag   = data.archive_file.task2.output_md5
}

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
  name               = "${var.player_id}-task2-02-bastion-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
resource "aws_iam_instance_profile" "bastion" {
  name = "${var.player_id}-task2-02-bastion-profile"
  role = aws_iam_role.bastion.name
}
resource "aws_security_group" "bastion" {
  name        = "${var.player_id}-task2-02-bastion-sg"
  description = "egress only (SSM)"
  vpc_id      = aws_vpc.bn.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.player_id}-task2-02-bastion-sg" }
}
locals {
  user_data = templatefile("${path.module}/userdata.sh.tpl", {
    bucket = aws_s3_bucket.bootstrap.id
    key    = aws_s3_object.bundle.key
    region = var.region
  })
}
resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.bn.id
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids = [aws_security_group.bastion.id]
  user_data              = local.user_data
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }
  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }
  tags       = { Name = "${var.player_id}-task2-02-bastion" }
  depends_on = [aws_s3_object.bundle]
}
