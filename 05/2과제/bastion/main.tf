# =============================================================================
# 1?¨ê³„ (ë¡œì»¬ Windows PowerShell?ì„œ apply) - ë°°í¬??Bastion EC2
#   - ëª©ì : Windows ë¡œì»¬ ?€??Linux Bastion ?ˆì—??05/2ê³¼ì œ ë£¨íŠ¸(4ê°?ëª¨ë“ˆ)ë¥?#           terraform apply ?œë‹¤. 2ê³¼ì œ??ëª¨ë“  provisioner(.ps1)ê°€ bash(.sh)ë¡?#           ë³€?˜ë˜???ˆì–´ Linux Bastion ?ì„œ ?•ìƒ ?™ì‘?œë‹¤.
#   - ?‘ì†: SSM Session Manager (SSH ???¸ë°”?´ë“œ ë¶ˆí•„??
#   - ê¶Œí•œ: ?¸ìŠ¤?´ìŠ¤ ?„ë¡œ?Œì¼(AdministratorAccess)ë¡?terraform ?ê²©ì¦ëª… ?ë™ ?¬ìš©
#   - ?ë™?? ë£¨íŠ¸(../) 2ê³¼ì œ ì½”ë“œ(files/ + module*/lambda + *.py + *.md ?¬í•¨)ë¥?#            zip ?¼ë¡œ ë¬¶ì–´ ë¶€?¸ìŠ¤?¸ë© S3 ???…ë¡œ????user_data ê°€ ?´ë ¤ë°›ì•„
#            /opt/task2 ??ì¤€ë¹? SSM ?‘ì† ??`bash /opt/task2/deploy.sh` ??ì¤„ë¡œ
#            4ê°?ëª¨ë“ˆ(us-east-1 / ap-southeast-1 / ap-northeast-2 / eu-central-1)??#            ??ë²ˆì— ë°°í¬?œë‹¤.
#
# ?????´ë”(state)??ë£¨íŠ¸(2ê³¼ì œ)?€ ë¶„ë¦¬?˜ì–´ ?ˆë‹¤. ì±„ì  ?????´ë”?ì„œë§?#   `terraform destroy` ?˜ë©´ Bastion(+ë¶€?¸ìŠ¤?¸ë© ë²„í‚·)ë§??œê±°?œë‹¤.
#   ë£¨íŠ¸ 2ê³¼ì œ state(../terraform.tfstate)???ˆë? ê±´ë“œë¦¬ì? ?ŠëŠ”??
# =============================================================================

data "aws_caller_identity" "current" {}

# ---- ê¸°ë³¸ VPC / ?œë¸Œ???¬ìš© (ì±„ì  ?€??VPC?€ ë¬´ê?) ----
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
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# =============================================================================
# ë£¨íŠ¸(2ê³¼ì œ) ì½”ë“œ ë²ˆë“¤ë§???ë¶€?¸ìŠ¤?¸ë© S3 ?…ë¡œ??#  - source_dir : ?ìœ„ 2ê³¼ì œ ?´ë”(?„ì¬ ë¡œì»¬ ?Œì¼)
#  - ?œì™¸       : bastion ?´ë”, ëª¨ë“  .terraform / state / backup / lock / plan
#                 (ë¦¬ëˆ…??Bastion ?ì„œ ?ˆë¡œ init ?˜ë?ë¡??œì™¸)
#  - KEEP       : files/, module*/lambda, *.py, *.md (ë°°í¬???„ìš”)
#  - ë²ˆë“¤ zip ?€ 2ê³¼ì œ ?´ë” "ë°?(05/)???ì„±?˜ì—¬ ?ê¸° ?ì‹ ???¬í•¨?˜ì? ?Šê²Œ ?œë‹¤.
# =============================================================================
data "archive_file" "task2" {
  type        = "zip"
  source_dir  = "${path.module}/.."
  output_path = "${path.module}/../../.task2_bundle_05.zip"

  excludes = [
    # --- ë¶€?¸ìŠ¤?¸ë© ?ê¸° ?ì‹  ---
    "bastion",
    "bastion/**",
    # --- ì¤‘ì²©(nested) state/backup/lock/plan ---
    "**/.terraform",
    "**/.terraform/**",
    "**/terraform.tfstate",
    "**/terraform.tfstate.*",
    "**/*.backup",
    "**/.terraform.lock.hcl",
    "**/*.tfplan",
    # --- ë£¨íŠ¸ ?ˆë²¨ state/backup/lock/plan (?¼ë? archive ë²„ì „?ì„œ **/ ê°€ ë£¨íŠ¸ë¥?    #     ë§¤ì¹­?˜ì? ?ŠëŠ” ê²½ìš° ?€ë¹? ?ˆì „?˜ê²Œ ì¤‘ë³µ ì§€?? ---
    ".terraform",
    ".terraform/**",
    ".terraform.lock.hcl",
    "terraform.tfstate",
    "terraform.tfstate.backup",
    "*.backup",
    "*.tfplan",
  ]
}

resource "aws_s3_bucket" "bootstrap" {
  bucket        = "${var.player_id}-task2-05-bootstrap-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = { Name = "${var.player_id}-task2-05-bootstrap" }
}

resource "aws_s3_bucket_public_access_block" "bootstrap" {
  bucket                  = aws_s3_bucket.bootstrap.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "task2_bundle" {
  bucket = aws_s3_bucket.bootstrap.id
  key    = "task2-bundle.zip"
  source = data.archive_file.task2.output_path
  etag   = data.archive_file.task2.output_md5
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
  name               = "${var.player_id}-task2-05-bastion-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# SSM ?‘ì†??resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# terraform ??4ê°?ë¦¬ì „ ëª¨ë“  ë¦¬ì†Œ?¤ë? ?ì„±?????ˆë„ë¡?(?€??ê³„ì • ?œì • ?¬ìš©)
resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.player_id}-task2-05-bastion-profile"
  role = aws_iam_role.bastion.name
}

# ---- ë³´ì•ˆ ê·¸ë£¹: ?¸ë°”?´ë“œ 0ê°?(SSM ?€ ?„ì›ƒë°”ìš´??443ë§??¬ìš©) ----
resource "aws_security_group" "bastion" {
  name        = "${var.player_id}-task2-05-bastion-sg"
  description = "Bastion SG - no inbound, SSM via outbound 443 only"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "All outbound (SSM, S3, ECR, downloads, multi-region AWS APIs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.player_id}-task2-05-bastion-sg" }
}

# ---- user_data: ?„êµ¬ ?¤ì¹˜ + ì½”ë“œ ë²ˆë“¤ ?ë™ ì¤€ë¹?+ deploy.sh ?ì„± ----
locals {
  effective_pin = var.pin != "" ? var.pin : var.player_id

  user_data = templatefile("${path.module}/userdata.sh.tpl", {
    bucket      = aws_s3_bucket.bootstrap.id
    key         = aws_s3_object.task2_bundle.key
    region      = var.region
    player_id   = var.player_id
    pin         = local.effective_pin
    alarm_email = var.alarm_email
  })
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = tolist(data.aws_subnets.default.ids)[0]
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  associate_public_ip_address = true

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

  tags = { Name = "${var.player_id}-task2-05-bastion" }

  depends_on = [aws_s3_object.task2_bundle]
}
