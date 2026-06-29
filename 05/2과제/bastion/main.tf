# =============================================================================
# 1단계 (로컬 Windows PowerShell에서 apply) - 배포용 Bastion EC2
#   - 목적: Windows 로컬 대신 Linux Bastion 안에서 05/2과제 루트(4개 모듈)를
#           terraform apply 한다. 2과제의 모든 provisioner(.ps1)가 bash(.sh)로
#           변환되어 있어 Linux Bastion 에서 정상 동작한다.
#   - 접속: SSM Session Manager (SSH 키/인바운드 불필요)
#   - 권한: 인스턴스 프로파일(AdministratorAccess)로 terraform 자격증명 자동 사용
#   - 자동화: 루트(../) 2과제 코드(files/ + module*/lambda + *.py + *.md 포함)를
#            zip 으로 묶어 부트스트랩 S3 에 업로드 → user_data 가 내려받아
#            /opt/task2 에 준비. SSM 접속 후 `bash /opt/task2/deploy.sh` 한 줄로
#            4개 모듈(us-east-1 / ap-southeast-1 / ap-northeast-2 / eu-central-1)이
#            한 번에 배포된다.
#
# ※ 이 폴더(state)는 루트(2과제)와 분리되어 있다. 채점 전 이 폴더에서만
#   `terraform destroy` 하면 Bastion(+부트스트랩 버킷)만 제거된다.
#   루트 2과제 state(../terraform.tfstate)는 절대 건드리지 않는다.
# =============================================================================

data "aws_caller_identity" "current" {}

# ---- 기본 VPC / 서브넷 사용 (채점 대상 VPC와 무관) ----
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ---- 최신 Amazon Linux 2023 AMI ----
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
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
# 루트(2과제) 코드 번들링 → 부트스트랩 S3 업로드
#  - source_dir : 상위 2과제 폴더(현재 로컬 파일)
#  - 제외       : bastion 폴더, 모든 .terraform / state / backup / lock / plan
#                 (리눅스 Bastion 에서 새로 init 하므로 제외)
#  - KEEP       : files/, module*/lambda, *.py, *.md (배포에 필요)
#  - 번들 zip 은 2과제 폴더 "밖"(05/)에 생성하여 자기 자신을 포함하지 않게 한다.
# =============================================================================
data "archive_file" "task2" {
  type        = "zip"
  source_dir  = "${path.module}/.."
  output_path = "${path.module}/../../.task2_bundle_05.zip"

  excludes = [
    # --- 부트스트랩 자기 자신 ---
    "bastion",
    "bastion/**",
    # --- 중첩(nested) state/backup/lock/plan ---
    "**/.terraform",
    "**/.terraform/**",
    "**/terraform.tfstate",
    "**/terraform.tfstate.*",
    "**/*.backup",
    "**/.terraform.lock.hcl",
    "**/*.tfplan",
    # --- 루트 레벨 state/backup/lock/plan (일부 archive 버전에서 **/ 가 루트를
    #     매칭하지 않는 경우 대비, 안전하게 중복 지정) ---
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
  name               = "${var.player_id}-task2-05-bastion-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# SSM 접속용
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# terraform 이 4개 리전 모든 리소스를 생성할 수 있도록 (대회 계정 한정 사용)
resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.player_id}-task2-05-bastion-profile"
  role = aws_iam_role.bastion.name
}

# ---- 보안 그룹: 인바운드 0개 (SSM 은 아웃바운드 443만 사용) ----
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

# ---- user_data: 도구 설치 + 코드 번들 자동 준비 + deploy.sh 생성 ----
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

  # 번들 내용이 바뀌면 user_data 해시가 바뀌어 인스턴스가 교체된다.
  user_data = local.user_data

  metadata_options {
    http_tokens   = "required" # IMDSv2 강제
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = { Name = "${var.player_id}-task2-05-bastion" }

  depends_on = [aws_s3_object.task2_bundle]
}
