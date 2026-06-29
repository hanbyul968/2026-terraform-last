# =============================================================================
# 1?¨ê³„ (ë¡œì»¬ Windows PowerShell ?ì„œ apply) ??ë°°í¬??Bastion EC2
#   - ëª©ì : Windows ë¡œì»¬ ?€??Linux Bastion ?ˆì—??2ê³¼ì œ 4ê°?ëª¨ë“ˆ ?„ì²´ë¥?#           terraform apply + docker build/push + kubectl/helm ?¼ë¡œ ë°°í¬?œë‹¤.
#           (ë¡œì»¬??Docker/kubectl/helm ë¶ˆí•„????ë¡œì»¬?€ ??bastion apply ë§?
#   - ?‘ì†: SSM Session Manager (SSH ???¸ë°”?´ë“œ ë¶ˆí•„??
#   - ê¶Œí•œ: ?¸ìŠ¤?´ìŠ¤ ?„ë¡œ?Œì¼(AdministratorAccess) ??ë©€?°ë¦¬??ë°°í¬ ?ê²©ì¦ëª… ?ë™
#   - ?ë™?? ?ìœ„(2ê³¼ì œ) ì½”ë“œ ?„ì²´ë¥?zip ?¼ë¡œ ë¬¶ì–´ ë¶€?¸ìŠ¤?¸ë© S3 ???…ë¡œ????#            user_data ê°€ ?´ë ¤ë°›ì•„ /opt/task2 ??ì¤€ë¹„í•˜ê³? /opt/task2/deploy.sh
#            ??ì¤„ë¡œ module1~4 ê°€ README ?œì„œ?€ë¡?ë°°í¬?œë‹¤.
#
# ?????´ë”(state)??ê°?ëª¨ë“ˆ state ?€ ?„ì „??ë¶„ë¦¬?˜ì–´ ?ˆë‹¤. ì±„ì  ?????´ë”?ì„œë§?#   `terraform destroy` ?˜ë©´ Bastion(+ë¶€?¸ìŠ¤?¸ë© ë²„í‚·)ë§??œê±°?œë‹¤.
# =============================================================================

data "aws_caller_identity" "current" {}

# ---- ê¸°ë³¸ VPC / ?œë¸Œ???¬ìš© (ì±„ì  ?€??VPC ?€ ë¬´ê?, ë¶ˆí•„??VPC ?ì„± ë°©ì?) ----
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
# ?ìœ„(2ê³¼ì œ) ì½”ë“œ ë²ˆë“¤ë§???ë¶€?¸ìŠ¤?¸ë© S3 ?…ë¡œ??#  - source_dir : ?ìœ„ 2ê³¼ì œ ?´ë”(module1~4 + ?ŒìŠ¤/ë§¤ë‹ˆ?˜ìŠ¤??yaml/lambda.zip/*.py)
#  - ?œì™¸       : bastion, ëª¨ë“  state/.terraform/lock/plan/.rendered (ë¦¬ëˆ…?¤ì—???ˆë¡œ init)
#  - ë²ˆë“¤ zip ?€ 2ê³¼ì œ ?´ë” "ë°?(06/)???ì„±?˜ì—¬ ?ê¸° ?ì‹ ???¬í•¨?˜ì? ?Šê²Œ ?œë‹¤.
# =============================================================================
data "archive_file" "task2" {
  type        = "zip"
  source_dir  = "${path.module}/.."
  output_path = "${path.module}/../../.task2_06_bundle.zip"

  # ?íƒœ/ìºì‹œ/?Œëœ/?Œë”ë§??°ì¶œë¬¼ì? ëª¨ë‘ ?œì™¸?˜ê³ , app/manifest/yaml/lambda.zip/*.py ??ë³´ì¡´.
  # ('**/' doublestar ?€ '*/' 1-depth, bare-root ?•íƒœë¥?ëª¨ë‘ ?¬í•¨??ë§¤ì²˜ ë²„ì „ê³?ë¬´ê??˜ê²Œ ?ˆì „)
  excludes = [
    "bastion",
    "bastion/**",
    ".terraform",
    ".terraform/**",
    "*/.terraform",
    "*/.terraform/**",
    "**/.terraform",
    "**/.terraform/**",
    "terraform.tfstate",
    "terraform.tfstate.backup",
    "*/terraform.tfstate",
    "*/terraform.tfstate.backup",
    "*/terraform.tfstate.*",
    "**/terraform.tfstate",
    "**/terraform.tfstate.*",
    ".terraform.lock.hcl",
    "*/.terraform.lock.hcl",
    "**/.terraform.lock.hcl",
    "*.tfplan",
    "*/*.tfplan",
    "**/*.tfplan",
    ".rendered",
    ".rendered/**",
    "*/.rendered",
    "*/.rendered/**",
    "**/.rendered/**",
  ]
}

resource "aws_s3_bucket" "bootstrap" {
  bucket        = "${var.player_id}-task2-06-bootstrap-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = { Name = "${var.player_id}-task2-06-bootstrap" }
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

# deploy.sh ??templatefile ??${} ê°„ì„­???¼í•˜ê¸??„í•´ ë³„ë„ raw ?¤ë¸Œ?íŠ¸ë¡??…ë¡œ?œí•œ??
# user_data ê°€ ???¤ë¸Œ?íŠ¸ë¥?/opt/task2/deploy.sh ë¡??´ë ¤ë°›ì•„(=writes) ?¤í–‰ ê¶Œí•œ??ì¤€??
resource "aws_s3_object" "deploy_sh" {
  bucket = aws_s3_bucket.bootstrap.id
  key    = "deploy.sh"
  source = "${path.module}/deploy.sh"
  etag   = filemd5("${path.module}/deploy.sh")
}

# ---- IAM Role + Instance Profile (SSM + AdministratorAccess) ----
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
  name               = "${var.player_id}-task2-06-bastion-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# SSM ?‘ì†??resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ë©€?°ë¦¬??4ê°?ëª¨ë“ˆ ?„ì²´ë¥??ì„±?????ˆë„ë¡?(?€??ê³„ì • ?œì • ?¬ìš©)
resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.player_id}-task2-06-bastion-profile"
  role = aws_iam_role.bastion.name
}

# ---- ë³´ì•ˆ ê·¸ë£¹: ?¸ë°”?´ë“œ 0ê°?(SSM ?€ ?„ì›ƒë°”ìš´??443ë§??¬ìš©) ----
resource "aws_security_group" "bastion" {
  name        = "${var.player_id}-task2-06-bastion-sg"
  description = "Bastion SG - no inbound, SSM via outbound 443 only"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "All outbound (SSM, ECR, docker pull/push, EKS API, helm charts)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.player_id}-task2-06-bastion-sg" }
}

# ---- user_data: ?„êµ¬ ?¤ì¹˜ + ì½”ë“œ ë²ˆë“¤ + deploy.sh ?ë™ ì¤€ë¹?----
locals {
  user_data = templatefile("${path.module}/userdata.sh.tpl", {
    bucket            = aws_s3_bucket.bootstrap.id
    bundle_key        = aws_s3_object.task2_bundle.key
    deploy_key        = aws_s3_object.deploy_sh.key
    region            = var.region
    competitor_number = var.competitor_number
  })
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = tolist(data.aws_subnets.default.ids)[0]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids = [aws_security_group.bastion.id]

  # ë²ˆë“¤/?¤í¬ë¦½íŠ¸ ?´ìš©??ë°”ë€Œë©´ user_data ?´ì‹œê°€ ë°”ë€Œì–´ ?¸ìŠ¤?´ìŠ¤ê°€ êµì²´?œë‹¤.
  user_data = local.user_data

  metadata_options {
    http_tokens   = "required" # IMDSv2 ê°•ì œ
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 40
    volume_type = "gp3"
  }

  tags = { Name = "${var.player_id}-task2-06-bastion" }

  depends_on = [
    aws_s3_object.task2_bundle,
    aws_s3_object.deploy_sh,
  ]
}
