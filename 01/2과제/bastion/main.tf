# =============================================================================
# 1단계 (로컬 Windows PowerShell에서 apply) - 배포용 Bastion EC2
#   - 목적: Windows 로컬 대신 Linux Bastion 안에서 2과제 4개 모듈
#           (module-1 ~ module-4, 멀티 리전)을 terraform apply 한다.
#           module-2 의 pymysql Lambda Layer 빌드(local-exec)가 bash 이므로
#           Linux Bastion 에서만 정상 동작한다.
#   - 접속: SSM Session Manager (SSH 키/인바운드 불필요)
#   - 권한: 인스턴스 프로파일(AdministratorAccess)로 terraform 자격증명 자동 사용
#   - 자동화: 상위(../) 2과제 코드(module-* / lambda / src 포함)를 zip 으로 묶어
#            부트스트랩 S3 에 업로드 -> user_data 가 내려받아 /opt/task2 에 준비.
#            SSM 접속 후 `bash /opt/task2/deploy.sh` 한 줄로 4개 모듈이 순서대로
#            배포된다. (module-1 -> module-2 -> module-3 -> module-4)
#
# ※ 이 폴더(state)는 module-* 와 분리되어 있다. 채점 전 이 폴더에서만
#   `terraform destroy` 하면 Bastion(+부트스트랩 버킷)만 제거된다.
#
# ※ 권위 모듈 세트: module-1 ~ module-4 (각 폴더에 main.tf + lambda/ 존재).
#   중복으로 보이는 빈 module1~module4 세트(.tf 없음)는 디스크에 그대로 두되
#   deploy.sh 배포 순서에서는 제외한다.
# =============================================================================

data "aws_caller_identity" "current" {}

# ---- 기본 VPC / 서브넷 사용 (채점 대상 VPC와 무관, 새 VPC 생성 안 함) ----
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
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# =============================================================================
# 상위(2과제) 코드 번들링 -> 부트스트랩 S3 업로드
#  - source_dir : 상위 2과제 폴더(현재 로컬 파일, module-* / lambda / src 포함)
#  - 제외       : bastion 폴더, .terraform, state, lock, plan (리눅스에서 새로 init)
#  - 번들 zip 은 2과제 폴더 "밖"(01/)에 생성하여 자기 자신을 포함하지 않게 한다.
# =============================================================================
data "archive_file" "task2" {
  type        = "zip"
  source_dir  = "${path.module}/.."
  output_path = "${path.module}/../../.task2_bundle_01.zip"

  excludes = [
    "bastion",
    "bastion/**",
    "**/.terraform",
    "**/.terraform/**",
    "**/terraform.tfstate",
    "**/terraform.tfstate.*",
    "**/.terraform.lock.hcl",
    "**/*.tfplan",
    # 빌드 산출물(리눅스에서 새로 생성됨) - 스테일 아티팩트 번들 방지
    "**/*.zip",
    "**/layer/**",
    ".gitignore",
  ]
}

resource "aws_s3_bucket" "bootstrap" {
  bucket        = "${var.player_id}-task2-01-bootstrap-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = { Name = "${var.player_id}-task2-01-bootstrap" }
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
  name               = "${var.player_id}-task2-bastion-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# SSM 접속용
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# terraform 이 4개 모듈(멀티 리전)의 모든 리소스를 생성할 수 있도록 (대회 계정 한정)
resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.player_id}-task2-bastion-profile"
  role = aws_iam_role.bastion.name
}

# ---- 보안 그룹: 인바운드 0개 (SSM 은 아웃바운드 443만 사용) ----
resource "aws_security_group" "bastion" {
  name        = "${var.player_id}-task2-bastion-sg"
  description = "Bastion SG - no inbound, SSM via outbound 443 only"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "All outbound (SSM, multi-region AWS APIs, pip, docker)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.player_id}-task2-bastion-sg" }
}

# ---- user_data: 도구 설치 + 코드 번들 자동 준비 + deploy.sh 생성 ----
locals {
  user_data = templatefile("${path.module}/userdata.sh.tpl", {
    bucket    = aws_s3_bucket.bootstrap.id
    key       = aws_s3_object.task2_bundle.key
    region    = var.region
    player_id = var.player_id
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

  tags = { Name = "${var.player_id}-task2-bastion" }

  depends_on = [aws_s3_object.task2_bundle]
}
