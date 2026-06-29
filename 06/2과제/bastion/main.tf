# =============================================================================
# 1단계 (로컬 Windows PowerShell 에서 apply) — 배포용 Bastion EC2
#   - 목적: Windows 로컬 대신 Linux Bastion 안에서 2과제 4개 모듈 전체를
#           terraform apply + docker build/push + kubectl/helm 으로 배포한다.
#           (로컬에 Docker/kubectl/helm 불필요 — 로컬은 이 bastion apply 만)
#   - 접속: SSM Session Manager (SSH 키/인바운드 불필요)
#   - 권한: 인스턴스 프로파일(AdministratorAccess) → 멀티리전 배포 자격증명 자동
#   - 자동화: 상위(2과제) 코드 전체를 zip 으로 묶어 부트스트랩 S3 에 업로드 →
#            user_data 가 내려받아 /opt/task2 에 준비하고, /opt/task2/deploy.sh
#            한 줄로 module1~4 가 README 순서대로 배포된다.
#
# ※ 이 폴더(state)는 각 모듈 state 와 완전히 분리되어 있다. 채점 전 이 폴더에서만
#   `terraform destroy` 하면 Bastion(+부트스트랩 버킷)만 제거된다.
# =============================================================================

data "aws_caller_identity" "current" {}

# ---- 기본 VPC / 서브넷 사용 (채점 대상 VPC 와 무관, 불필요 VPC 생성 방지) ----
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
# 상위(2과제) 코드 번들링 → 부트스트랩 S3 업로드
#  - source_dir : 상위 2과제 폴더(module1~4 + 소스/매니페스트/yaml/lambda.zip/*.py)
#  - 제외       : bastion, 모든 state/.terraform/lock/plan/.rendered (리눅스에서 새로 init)
#  - 번들 zip 은 2과제 폴더 "밖"(06/)에 생성하여 자기 자신을 포함하지 않게 한다.
# =============================================================================
data "archive_file" "task2" {
  type        = "zip"
  source_dir  = "${path.module}/.."
  output_path = "${path.module}/../../.task2_06_bundle.zip"

  # 상태/캐시/플랜/렌더링 산출물은 모두 제외하고, app/manifest/yaml/lambda.zip/*.py 는 보존.
  # ('**/' doublestar 와 '*/' 1-depth, bare-root 형태를 모두 포함해 매처 버전과 무관하게 안전)
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

# deploy.sh 는 templatefile 의 ${} 간섭을 피하기 위해 별도 raw 오브젝트로 업로드한다.
# user_data 가 이 오브젝트를 /opt/task2/deploy.sh 로 내려받아(=writes) 실행 권한을 준다.
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

# SSM 접속용
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 멀티리전 4개 모듈 전체를 생성할 수 있도록 (대회 계정 한정 사용)
resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.player_id}-task2-06-bastion-profile"
  role = aws_iam_role.bastion.name
}

# ---- 보안 그룹: 인바운드 0개 (SSM 은 아웃바운드 443만 사용) ----
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

# ---- user_data: 도구 설치 + 코드 번들 + deploy.sh 자동 준비 ----
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

  # 번들/스크립트 내용이 바뀌면 user_data 해시가 바뀌어 인스턴스가 교체된다.
  user_data = local.user_data

  metadata_options {
    http_tokens   = "required" # IMDSv2 강제
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
