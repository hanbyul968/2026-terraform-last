# =============================================================================
# 03/2Í≥ºÏ†ú 1?®Í≥Ñ (Î°úÏª¨ Windows PowerShell ?êÏÑú apply) - Î∞∞Ìè¨??Bastion EC2
#   - Î™©Ï†Å: Windows Î°úÏª¨ ?Ä??Linux Bastion ?àÏóê??2Í≥ºÏ†ú 4Í∞?Î™®Îìà
#           (module1~module4, Î©Ä??Î¶¨Ï†Ñ)??terraform apply ?úÎã§.
#           module1 Pillow ÎπåÎìú(build.sh), module2 saml-iam.sh,
#           module3 helm/kubectl(deploy_k8s.sh) Î™®Îëê bash ?¥Î?Î°?Linux ?ÑÏàò.
#   - ?ëÏÜç: SSM Session Manager (SSH ???∏Î∞î?¥Îìú Î∂àÌïÑ??
#   - Í∂åÌïú: ?∏Ïä§?¥Ïä§ ?ÑÎ°ú?åÏùº(AdministratorAccess)
#   - ?êÎèô?? ?ÅÏúÑ(../) 2Í≥ºÏ†ú ÏΩîÎìúÎ•?zip ?ºÎ°ú Î¨∂Ïñ¥ Î∂Ä?∏Ïä§?∏Îû© S3 ???ÖÎ°ú??->
#            user_data Í∞Ä ?¥Î†§Î∞õÏïÑ /opt/task2 Ï§ÄÎπ? SSM ?ëÏÜç ??#            `bash /opt/task2/deploy.sh` Î°?module1->module4 + EKS k8s ?®Í≥ÑÍπåÏ? Î∞∞Ìè¨.
#
#   ?????¥Îçî(state)??module1~module4 ?Ä Î∂ÑÎ¶¨?òÏñ¥ ?àÎã§. Ï±ÑÏ†ê ?????¥Îçî?êÏÑúÎß?#     terraform destroy ?òÎ©¥ Bastion(+Î∂Ä?∏Ïä§?∏Îû© Î≤ÑÌÇ∑)Îß??úÍ±∞?úÎã§.
#   ??module3 EKS ??Ï±ÑÏ†ê??PUBLIC endpoint Î•??îÍµ¨?òÎ?Î°??´Ï? ?äÎäî??
# =============================================================================

data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  default = true
}

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

# ---- ?ÅÏúÑ(2Í≥ºÏ†ú) ÏΩîÎìú Î≤àÎì§Îß?-> Î∂Ä?∏Ïä§?∏Îû© S3 ----
data "archive_file" "task2" {
  type        = "zip"
  source_dir  = "${path.module}/.."
  output_path = "${path.module}/../../.task2_bundle_03.zip"

  excludes = [
    "bastion",
    "bastion/**",
    "**/.terraform",
    "**/.terraform/**",
    "**/terraform.tfstate",
    "**/terraform.tfstate.*",
    "**/.terraform.lock.hcl",
    "**/*.tfplan",
    "**/*.zip",
    "**/build/**",
    "**/resize_pkg/**",
    ".gitignore",
  ]
}

resource "aws_s3_bucket" "bootstrap" {
  bucket        = "${var.player_id}-task2-03-bootstrap-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = { Name = "${var.player_id}-task2-03-bootstrap" }
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

# ---- IAM Role + Instance Profile (SSM + Î∞∞Ìè¨ Í∂åÌïú) ----
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
  name               = "${var.player_id}-task2-03-bastion-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
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
  name = "${var.player_id}-task2-03-bastion-profile"
  role = aws_iam_role.bastion.name
}

# ---- Î≥¥Ïïà Í∑∏Î£π: ?∏Î∞î?¥Îìú 0Í∞?(SSM ?ÑÏõÉÎ∞îÏö¥??443Îß? ----
resource "aws_security_group" "bastion" {
  name        = "${var.player_id}-task2-03-bastion-sg"
  description = "Bastion SG - no inbound, SSM via outbound only"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "All outbound (SSM, multi-region AWS APIs, pip, helm, docker)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.player_id}-task2-03-bastion-sg" }
}

# ---- user_data ----
locals {
  user_data = templatefile("${path.module}/userdata.sh.tpl", {
    bucket    = aws_s3_bucket.bootstrap.id
    key       = aws_s3_object.task2_bundle.key
    region    = var.region
    player_id = var.player_id
    pin       = var.pin
  })
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = tolist(data.aws_subnets.default.ids)[0]
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  associate_public_ip_address = true

  user_data = local.user_data

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 40
    volume_type = "gp3"
  }

  tags = { Name = "${var.player_id}-task2-03-bastion" }

  depends_on = [aws_s3_object.task2_bundle]
}
