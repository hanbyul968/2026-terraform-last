# =============================================================================
# 1단계 (로컬 Windows PowerShell 에서 apply) — 2과제(08) 배포 전용 Bastion EC2
#   - 목적: Windows 로컬 대신 Linux Bastion 안에서 루트(서버리스 3개) + module4_rds
#           를 terraform apply 한다. (Module3 SFN 실행/ result.json 생성 등 bash 단계 포함)
#   - 접속: SSM Session Manager (SSH 키/인바운드 불필요)
#   - 권한: 인스턴스 프로파일(AdministratorAccess)로 terraform 자격증명 자동 사용
#   - 자동화: 상위(../) 2과제 코드 전체를 zip 으로 묶어 부트스트랩 S3 에 업로드 →
#            user_data 가 내려받아 /opt/task2 에 풀고 /opt/task2/deploy.sh 생성.
#            SSM 접속 후 `bash /opt/task2/deploy.sh <비번호>` 한 줄로 전체 배포 수행.
#
# ※ 이 폴더(state)는 루트/module4_rds state 와 완전히 분리되어 있다. 채점 전 이 폴더에서만
#   `terraform destroy` 하면 Bastion(+부트스트랩 버킷)만 제거된다.
# ※ archive 는 모든 state/backup/.terraform/lock/plan 을 제외한다(리눅스에서 새로 init).
# ※ 채점은 Bastion 을 사용하지 않고 CloudShell 에서 수행한다(채점지 유의사항).
# =============================================================================

data "aws_caller_identity" "current" {}

# ---- Bastion 전용 VPC (이 대회 계정엔 default VPC 가 없음) ----
resource "aws_vpc" "bn" {
  cidr_block           = "10.250.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "task-bastion-vpc" }
}
resource "aws_internet_gateway" "bn" {
  vpc_id = aws_vpc.bn.id
  tags   = { Name = "task-bastion-igw" }
}
resource "aws_subnet" "bn" {
  vpc_id                  = aws_vpc.bn.id
  cidr_block              = "10.250.0.0/24"
  map_public_ip_on_launch = true
  tags                    = { Name = "task-bastion-subnet" }
}
resource "aws_route_table" "bn" {
  vpc_id = aws_vpc.bn.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.bn.id
  }
  tags = { Name = "task-bastion-rt" }
}
resource "aws_route_table_association" "bn" {
  subnet_id      = aws_subnet.bn.id
  route_table_id = aws_route_table.bn.id
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
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# =============================================================================
# 상위(2과제) 코드 번들링 → 부트스트랩 S3 업로드
#  - source_dir : 상위 2과제 폴더(module*.tf, module4_rds/, files/, *.tf)
#  - 제외       : bastion 폴더, .terraform, 모든 state/backup, lock, plan
#  - 번들 zip 은 2과제 폴더 "밖"(08/)에 생성하여 자기 자신을 포함하지 않게 한다.
# =============================================================================
data "archive_file" "task2" {
  type        = "zip"
  source_dir  = "${path.module}/.."
  output_path = "${path.module}/../../.task2_bundle_08.zip"

  excludes = [
    "bastion",
    "bastion/**",
    "**/.terraform",
    "**/.terraform/**",
    "**/terraform.tfstate",
    "**/terraform.tfstate.*",
    "**/.terraform.tfstate.lock.info",
    "**/.terraform.lock.hcl",
    "**/*.tfplan",
  ]
}

resource "aws_s3_bucket" "bootstrap" {
  bucket        = "${var.player_id}-task2-08-bootstrap-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = { Name = "${var.player_id}-task2-08-bootstrap" }
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
  name               = "${var.player_id}-task2-08-bastion-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# SSM 접속용
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# terraform 이 모든 리소스를 생성할 수 있도록 (대회 계정 한정 사용)
resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.player_id}-task2-08-bastion-profile"
  role = aws_iam_role.bastion.name
}

# ---- 보안 그룹: 인바운드 0개 (SSM 은 아웃바운드 443만 사용) ----
resource "aws_security_group" "bastion" {
  name        = "${var.player_id}-task2-08-bastion-sg"
  description = "Bastion SG - no inbound, SSM via outbound 443 only"
  vpc_id      = aws_vpc.bn.id

  egress {
    description = "All outbound (SSM, S3, RDS/Data API, terraform providers)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.player_id}-task2-08-bastion-sg" }
}

# ---- user_data: 도구 설치 + 코드 번들 자동 준비 + deploy.sh 생성 ----
locals {
  user_data = templatefile("${path.module}/userdata.sh.tpl", {
    bucket    = aws_s3_bucket.bootstrap.id
    key       = aws_s3_object.task2_bundle.key
    region    = var.region
    player_id = var.player_id
    team_id   = var.team_id
  })
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.bn.id
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids = [aws_security_group.bastion.id]

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

  tags = { Name = "${var.player_id}-task2-08-bastion" }

  depends_on = [aws_s3_object.task2_bundle]
}
