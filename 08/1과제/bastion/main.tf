# =============================================================================
# Bastion EC2 (ë°°í¬ ?‘ì—…??
#  - ëª©ì : Windows ë¡œì»¬ ?€?? ??EC2??SSM?¼ë¡œ ?‘ì†??main terraform apply
#          + docker build/push ë¥??˜í–‰?œë‹¤.
#  - ?‘ì†: SSM Session Manager (SSH ???¸ë°”?´ë“œ ë¶ˆí•„??
#  - ê¶Œí•œ: ?¸ìŠ¤?´ìŠ¤ ?„ë¡œ?Œì¼(AdministratorAccess)ë¡?terraform???ê²©ì¦ëª… ?ë™ ?¬ìš©
#  - ?ë™?? ë¡œì»¬??"?„ì¬" 1ê³¼ì œ ì½”ë“œ(app/book, static/* ?¬í•¨)ë¥?zip?¼ë¡œ ë¬¶ì–´
#           ë¶€?¸ìŠ¤?¸ë© S3 ë²„í‚·???…ë¡œ????user_dataê°€ ?´ë ¤ë°›ì•„ /opt/task1??ì¤€ë¹?
#           SSM ?‘ì† ??`bash /opt/task1/run.sh` ??ì¤„ì´ë©?main ?¸í”„?¼ê? ë°°í¬?œë‹¤.
#
# ?????´ë”(state)??mainê³?ë¶„ë¦¬?˜ì–´ ?ˆë‹¤. ì±„ì  ?????´ë”?ì„œë§?#   `terraform destroy` ?˜ë©´ Bastion(+ë¶€?¸ìŠ¤?¸ë© ë²„í‚·)ë§??œê±°?˜ì–´
#   8-2(ë¶ˆí•„??ë¦¬ì†Œ?? ê°ì ???¼í•œ?? (ì±„ì ?€ CloudShell?ì„œ ì§„í–‰)
# =============================================================================

data "aws_caller_identity" "current" {}

# ---- ê¸°ë³¸ VPC / ?œë¸Œ???¬ìš© (main VPC?€ ë¬´ê?) ----
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ---- ìµœì‹  Amazon Linux 2023 AMI ----
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

# =============================================================================
# ë¡œì»¬ 1ê³¼ì œ ì½”ë“œ ë²ˆë“¤ë§???ë¶€?¸ìŠ¤?¸ë© S3 ?…ë¡œ??#  - source_dir : ?ìœ„ 1ê³¼ì œ ?´ë”(?„ì¬ ë¡œì»¬ ?Œì¼)
#  - ?œì™¸       : bastion ?´ë”, .terraform, state, lock, plan (ë¦¬ëˆ…?¤ì—???ˆë¡œ init)
#  - ë²ˆë“¤ zip?€ 1ê³¼ì œ ?´ë” "ë°?(08/)???ì„±?˜ì—¬ ?ê¸° ?ì‹ ???¬í•¨?˜ì? ?Šê²Œ ?œë‹¤.
# =============================================================================
data "archive_file" "task1" {
  type        = "zip"
  source_dir  = "${path.module}/.."
  output_path = "${path.module}/../../.task1_bundle.zip"

  excludes = [
    "bastion",
    "bastion/**",
    ".terraform",
    ".terraform/**",
    ".terraform.lock.hcl",
    "terraform.tfstate",
    "terraform.tfstate.backup",
    "*.tfplan",
    ".gitignore",
  ]
}

resource "aws_s3_bucket" "bootstrap" {
  bucket        = "${var.player_id}-bastion-bootstrap-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name = "${var.player_id}-bastion-bootstrap"
  }
}

resource "aws_s3_bucket_public_access_block" "bootstrap" {
  bucket                  = aws_s3_bucket.bootstrap.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "task1_bundle" {
  bucket = aws_s3_bucket.bootstrap.id
  key    = "task1-bundle.zip"
  source = data.archive_file.task1.output_path
  etag   = data.archive_file.task1.output_md5
}

# ---- IAM Role + Instance Profile (SSM + ë°°í¬ ê¶Œí•œ) ----
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

# SSM ?‘ì†??resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# terraform??ëª¨ë“  ë¦¬ì†Œ?¤ë? ?ì„±?????ˆë„ë¡?(?€??ê³„ì • ?œì • ?¬ìš©)
resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.player_id}-bastion-profile"
  role = aws_iam_role.bastion.name
}

# ---- ë³´ì•ˆ ê·¸ë£¹: ?¸ë°”?´ë“œ 0ê°?(SSM?€ ?„ì›ƒë°”ìš´??443ë§??¬ìš©) ----
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

# ---- user_data: ?„êµ¬ ?¤ì¹˜ + ì½”ë“œ ë²ˆë“¤ ?ë™ ì¤€ë¹?----
locals {
  user_data = templatefile("${path.module}/userdata.sh.tpl", {
    bucket    = aws_s3_bucket.bootstrap.id
    key       = aws_s3_object.task1_bundle.key
    region    = var.region
    player_id = var.player_id
  })
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = tolist(data.aws_subnets.default.ids)[0]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids = [aws_security_group.bastion.id]

  # ë²ˆë“¤ ?´ìš©??ë°”ë€Œë©´ user_data ?´ì‹œê°€ ë°”ë€Œì–´ ?¸ìŠ¤?´ìŠ¤ê°€ êµì²´?œë‹¤.
  user_data = local.user_data

  metadata_options {
    http_tokens   = "required" # IMDSv2 ê°•ì œ
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = {
    Name = "${var.player_id}-bastion"
  }

  depends_on = [aws_s3_object.task1_bundle]
}
