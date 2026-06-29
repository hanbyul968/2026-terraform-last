# =============================================================================
# 2Í≥ºÏ†ú(04) Î∞∞Ìè¨??Bastion ??Î°úÏª¨ Windows PowerShell ?êÏÑú apply
#   - module1..4 (Î©Ä??Î¶¨Ï†Ñ) Î•?Bastion(Linux) ?àÏóê???úÏÑú?ÄÎ°?apply ?òÍ∏∞ ?ÑÌïú ÏßÑÏûÖ??
#   - ?ëÏÜç: SSM Session Manager. Í∂åÌïú: AdministratorAccess ?∏Ïä§?¥Ïä§ ?ÑÎ°ú?åÏùº.
#   - 2Í≥ºÏ†ú ÏΩîÎìú ?ÑÏ≤¥Î•?zip ?ºÎ°ú Î¨∂Ïñ¥ Î∂Ä?∏Ïä§?∏Îû© S3 ???ÖÎ°ú????user_data Í∞Ä
#     /opt/task2 Î°??¥Î†§Î∞õÍ≥† deploy.sh Î•??ùÏÑ±?úÎã§. SSM ?ëÏÜç ??`bash /opt/task2/deploy.sh`.
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
