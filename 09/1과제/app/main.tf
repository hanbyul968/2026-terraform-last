###############################################################################
# 2단계 (Bastion에서 실행) - VPC/Bastion을 제외한 모든 리소스
#   - bootstrap 단계(로컬)에서 만든 VPC/Subnet을 data source 로 조회
#   - KMS / DynamoDB / S3 / ECR / ALB / CloudFront / IAM / LogGroup / manifest 버킷
#   - EKS 클러스터 및 k8s 리소스는 기존대로 manifest/setup.sh 에서 생성
###############################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"
}

data "aws_caller_identity" "current" {}

# ========== bootstrap 단계에서 만든 VPC/Subnet 조회 ==========
# (이름 태그로 조회 - bootstrap 의 VPC 모듈 입력값과 반드시 일치해야 함)
data "aws_vpc" "this" {
  filter {
    name   = "tag:Name"
    values = ["worldpay-vpc"]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  filter {
    name   = "tag:Name"
    values = ["worldpay-public-subnet-a", "worldpay-public-subnet-c"]
  }
}

data "aws_subnets" "isolated" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  filter {
    name   = "tag:Name"
    values = ["worldpay-isolated-subnet-a", "worldpay-isolated-subnet-c"]
  }
}

# ========== KMS ==========
module "KMS" {
  source       = "../modules/KMS"
  db_key_alias = "alias/worldpay-db-key"
  s3_key_alias = "alias/worldpay-s3-key"
}

# ========== DynamoDB ==========
module "DynamoDB" {
  source      = "../modules/DynamoDB"
  table_name  = "Concerts"
  hash_key    = "booking_id"
  kms_key_arn = module.KMS.db_key_arn
}

# ========== S3 (정적 호스팅 버킷) ==========
module "S3" {
  source      = "../modules/S3"
  bucket_name = "worldpay-bucket-${data.aws_caller_identity.current.account_id}"
  kms_key_arn = module.KMS.s3_key_arn
}

# ========== ECR ==========
module "ECR" {
  source          = "../modules/ECR"
  repository_name = "worldpay-book"
}

# ========== EKS Pod Identity Role (Book App) ==========
resource "aws_iam_role" "book_app" {
  name = "worldpay-book-app-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "book_app" {
  name = "worldpay-book-app-policy"
  role = aws_iam_role.book_app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
        Resource = [module.DynamoDB.table_arn, "${module.DynamoDB.table_arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:Encrypt", "kms:DescribeKey"]
        Resource = ["*"]
      }
    ]
  })
}
# Pod Identity Association은 EKS 생성 후 manifest/setup.sh에서 관리

# ========== AWS Load Balancer Controller IAM Role ==========
resource "aws_iam_role" "albc" {
  name = "worldpay-albc-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "albc" {
  role       = aws_iam_role.albc.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ========== Book ALB (internal) ==========
resource "aws_security_group" "book_alb" {
  name   = "book-alb-sg"
  vpc_id = data.aws_vpc.this.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "book-alb-sg" }
}

resource "aws_lb" "book" {
  name               = "book-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.book_alb.id]
  subnets            = data.aws_subnets.isolated.ids
  tags               = { Name = "book-alb" }
}

resource "aws_lb_target_group" "book" {
  name        = "book-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.this.id
  target_type = "ip"

  health_check {
    path     = "/health"
    protocol = "HTTP"
    port     = "8080"
  }
  tags = { Name = "book-tg" }
}

resource "aws_lb_listener" "book" {
  load_balancer_arn = aws_lb.book.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.book.arn
  }
}

# ========== Grafana ALB (internet-facing) ==========
resource "aws_security_group" "grafana_alb" {
  name   = "grafana-alb-sg"
  vpc_id = data.aws_vpc.this.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "grafana-alb-sg" }
}

resource "aws_lb" "grafana" {
  name               = "grafana-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.grafana_alb.id]
  subnets            = data.aws_subnets.public.ids
  tags               = { Name = "grafana-alb" }
}

resource "aws_lb_target_group" "grafana" {
  name        = "grafana-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.this.id
  target_type = "ip"

  health_check {
    path     = "/api/health"
    protocol = "HTTP"
    port     = "3000"
  }
  tags = { Name = "grafana-tg" }
}

resource "aws_lb_listener" "grafana" {
  load_balancer_arn = aws_lb.grafana.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }
}

# ========== CloudWatch Log Group ==========
resource "aws_cloudwatch_log_group" "app" {
  name              = "/worldpay/application"
  retention_in_days = 7
  tags              = { Name = "/worldpay/application" }
}

# ========== Manifest S3 Bucket (k8s manifest + 배포파일 보관) ==========
resource "aws_s3_bucket" "manifest" {
  bucket_prefix = "worldpay-manifest-"
  force_destroy = true
}

resource "aws_s3_object" "manifests" {
  for_each = fileset("${path.root}/../manifest", "*")
  bucket   = aws_s3_bucket.manifest.id
  key      = each.value
  source   = "${path.root}/../manifest/${each.value}"
  etag     = filemd5("${path.root}/../manifest/${each.value}")
}

resource "aws_s3_object" "book_binary" {
  bucket = aws_s3_bucket.manifest.id
  key    = "book"
  source = "${path.root}/../배포파일/book-linux-amd64_v1.0.1"
  etag   = filemd5("${path.root}/../배포파일/book-linux-amd64_v1.0.1")
}

resource "aws_s3_object" "index_html" {
  bucket = aws_s3_bucket.manifest.id
  key    = "index.html"
  source = "${path.root}/../배포파일/index.html"
  etag   = filemd5("${path.root}/../배포파일/index.html")
}

resource "aws_s3_object" "main_jpeg" {
  bucket = aws_s3_bucket.manifest.id
  key    = "main.jpeg"
  source = "${path.root}/../배포파일/main.jpeg"
  etag   = filemd5("${path.root}/../배포파일/main.jpeg")
}

# ========== CloudFront ==========
module "CloudFront" {
  source                         = "../modules/CloudFront"
  distribution_name              = "worldpay-cdn"
  oac_name                       = "worldpay-s3-oac"
  s3_bucket_id                   = module.S3.bucket_id
  s3_bucket_arn                  = module.S3.bucket_arn
  s3_bucket_regional_domain_name = module.S3.bucket_regional_domain_name
  alb_dns_name                   = aws_lb.book.dns_name
  alb_arn                        = aws_lb.book.arn
}
