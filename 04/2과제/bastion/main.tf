# =============================================================================
# 2과제(04) 배포용 Bastion — 로컬 Windows PowerShell 에서 apply
#   - module1..4 (멀티 리전) 를 Bastion(Linux) 안에서 순서대로 apply 하기 위한 진입점.
#   - 접속: SSM Session Manager. 권한: AdministratorAccess 인스턴스 프로파일.
#   - 2과제 코드 전체를 zip 으로 묶어 부트스트랩 S3 에 업로드 → user_data 가
#     /opt/task2 로 내려받고 deploy.sh 를 생성한다. SSM 접속 후 `bash /opt/task2/deploy.sh`.
# =============================================================================

data "aws_caller_identity" "current" {}

data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
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
  output_path = "${path.module}/../../.task2_bundle_04.zip"
  excludes = [
    "bastion", "bastion/**",
    "**/.terraform", "**/.terraform/**",
    "**/terraform.tfstate", "**/terraform.tfstate.*",
    "**/.terraform.lock.hcl", "**/*.tfplan",
  ]
}

resource "aws_s3_bucket" "bootstrap" {
  bucket        = "${var.player_id}-task2-04-bootstrap-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = { Name = "${var.player_id}-task2-04-bootstrap" }
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
  name               = "${var.player_id}-task2-04-bastion-role"
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
  name = "${var.player_id}-task2-04-bastion-profile"
  role = aws_iam_role.bastion.name
}

resource "aws_security_group" "bastion" {
  name        = "${var.player_id}-task2-04-bastion-sg"
  description = "Bastion egress only (SSM)"
  vpc_id      = data.aws_vpc.default.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.player_id}-task2-04-bastion-sg" }
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
  subnet_id              = tolist(data.aws_subnets.default.ids)[0]
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
  tags       = { Name = "${var.player_id}-task2-04-bastion" }
  depends_on = [aws_s3_object.bundle]
}
