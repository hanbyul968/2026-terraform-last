# =============================================================================
# 03/2과제 1단계 (로컬 Windows PowerShell 에서 apply) - 배포용 Bastion EC2
#   - 목적: Windows 로컬 대신 Linux Bastion 안에서 2과제 4개 모듈
#           (module1~module4, 멀티 리전)을 terraform apply 한다.
#           module1 Pillow 빌드(build.sh), module2 saml-iam.sh,
#           module3 helm/kubectl(deploy_k8s.sh) 모두 bash 이므로 Linux 필수.
#   - 접속: SSM Session Manager (SSH 키/인바운드 불필요)
#   - 권한: 인스턴스 프로파일(AdministratorAccess)
#   - 자동화: 상위(../) 2과제 코드를 zip 으로 묶어 부트스트랩 S3 에 업로드 ->
#            user_data 가 내려받아 /opt/task2 준비. SSM 접속 후
#            `bash /opt/task2/deploy.sh` 로 module1->module4 + EKS k8s 단계까지 배포.
#
#   ※ 이 폴더(state)는 module1~module4 와 분리되어 있다. 채점 전 이 폴더에서만
#     terraform destroy 하면 Bastion(+부트스트랩 버킷)만 제거된다.
#   ※ module3 EKS 는 채점이 PUBLIC endpoint 를 요구하므로 닫지 않는다.
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

# ---- 상위(2과제) 코드 번들링 -> 부트스트랩 S3 ----
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

# ---- IAM Role + Instance Profile (SSM + 배포 권한) ----
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

# ---- 보안 그룹: 인바운드 0개 (SSM 아웃바운드 443만) ----
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
