# =============================================================================
# 1단계 (로컬 Windows PowerShell에서 apply) - 네트워크 기반 + 통합 Bastion
#   - 이 스테이지가 진짜 wsc-vpc / 서브넷 / IGW / NAT / 라우팅을 생성하고(network.tf),
#     그 안의 wsc-public-a(진짜 퍼블릭 서브넷)에 "통합 Bastion"(wsc-bastion)을 띄운다.
#   - 통합 Bastion 은 두 역할을 겸한다:
#       (1) 과제 5 채점 대상 Bastion : Name=wsc-bastion, EIP, SSH(22) 비번(Skill53##),
#           AdministratorAccess, kubectl/eksctl/sshpass 설치.
#       (2) 배포용 Bastion : root(../) 1과제 코드를 zip 으로 묶어 부트스트랩 S3 에 업로드 →
#           user_data 가 내려받아 /opt/task1 준비. SSH/SSM 접속 후
#           `bash /opt/task1/run.sh` 한 줄로 root 인프라(EKS/ALB/S3/...)가 배포된다.
#   - 접속: SSH(비번) 또는 SSM Session Manager 둘 다 가능.
#   - 덕분에 Bastion 이 클러스터와 "같은 VPC" 라, EKS private-only 전환 후에도
#     kubectl/포트포워딩이 계속 동작한다(채점 kubectl/브라우저 접속 포함).
#
# ※ 이 스테이지가 VPC 를 소유하므로, 채점 전에 이 스테이지를 destroy 하면 안 된다.
#   destroy 순서: 먼저 bastion 안에서 root(/opt/task1, /opt/task1/k8s) destroy →
#   그 다음 이 폴더(1단계)를 destroy.
# =============================================================================

data "aws_caller_identity" "current" {}

# ---- 네트워크(wsc-vpc/서브넷/IGW/NAT/RT)는 network.tf 에서 생성 ----
#   bastion 은 wsc-public-a(퍼블릭)에 위치하므로 EKS private-only 전환 후에도 접근 가능.

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
# 루트(1과제) 코드 번들링 → 부트스트랩 S3 업로드
#  - source_dir : 상위 1과제 폴더(현재 로컬 파일)
#  - 제외       : bastion 폴더, .terraform, state, lock, plan (리눅스에서 새로 init)
#  - 번들 zip 은 1과제 폴더 "밖"(04/)에 생성하여 자기 자신을 포함하지 않게 한다.
# =============================================================================
data "archive_file" "task1" {
  type        = "zip"
  source_dir  = "${path.module}/.."
  output_path = "${path.module}/../../.task1_bundle_04.zip"

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
    "*.OLD-in-main",
  ]
}

resource "aws_s3_bucket" "bootstrap" {
  bucket        = "${var.player_id}-task1-bootstrap-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = { Name = "${var.player_id}-task1-bootstrap" }
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

# ---- IAM Role + Instance Profile (SSM + 배포(Admin) 권한) ----
#   이름은 과제 5 채점용 통합 Bastion 이므로 wsc-bastion-* 로 통일한다.
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
  name               = "wsc-bastion-role"
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
  name = "wsc-bastion-profile"
  role = aws_iam_role.bastion.name
}

# ---- 보안 그룹: 진짜 wsc-vpc 안. SSH(22) 인바운드 허용(과제 5) + 전체 아웃바운드 ----
resource "aws_security_group" "bastion" {
  name        = "wsc-bastion-sg"
  description = "Bastion SG - SSH(22) inbound + all outbound (SSM, ECR, docker, EKS API, helm)"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH from anywhere (grading uses sshpass)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound (SSM, ECR, docker pull, EKS API, helm charts)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "wsc-bastion-sg" }
}

# ---- user_data: SSH 비번 설정 + 도구 설치 + 코드 번들 자동 준비 ----
locals {
  user_data = templatefile("${path.module}/userdata.sh.tpl", {
    bucket       = aws_s3_bucket.bootstrap.id
    key          = aws_s3_object.task1_bundle.key
    region       = var.region
    player_id    = var.player_id
    ssh_password = var.ssh_password
    cluster_name = local.cluster_name
  })
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public_a.id
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  associate_public_ip_address = true

  # 번들 내용이 바뀌면 user_data 해시가 바뀌어 인스턴스가 교체된다.
  user_data = local.user_data

  metadata_options {
    http_tokens   = "optional"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = { Name = "wsc-bastion" }

  depends_on = [aws_s3_object.task1_bundle, aws_route_table_association.public_a]
}

# 재시작해도 IP 고정 (과제 5) — Elastic IP
resource "aws_eip" "bastion" {
  instance = aws_instance.bastion.id
  domain   = "vpc"
  tags     = { Name = "wsc-bastion-eip" }
}
