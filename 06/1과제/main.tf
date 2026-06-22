terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

variable "number" {
  description = "선수 비번호"
  type        = string
}

provider "aws" {
  region = "ap-northeast-2"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

# ========== VPC ==========
module "VPC" {
  source               = "./modules/VPC"
  vpc_name             = "unicorn-vpc"
  vpc_cidr             = "10.97.0.0/16"
  public_subnets_cidr  = ["10.97.0.0/24", "10.97.1.0/24", "10.97.2.0/24"]
  private_subnets_cidr = ["10.97.10.0/24", "10.97.11.0/24", "10.97.12.0/24"]
  availability_zones   = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
  public_subnet_names  = ["unicorn-subnet-pub-a", "unicorn-subnet-pub-b", "unicorn-subnet-pub-c"]
  private_subnet_names = ["unicorn-subnet-priv-a", "unicorn-subnet-priv-b", "unicorn-subnet-priv-c"]
  igw_name             = "unicorn-igw"
  nat_eip_names        = ["unicorn-eip-nat-a", "unicorn-eip-nat-b", "unicorn-eip-nat-c"]
  nat_gw_names         = ["unicorn-nat-a", "unicorn-nat-b", "unicorn-nat-c"]
  public_rt_name       = "unicorn-rt-pub"
  private_rt_names     = ["unicorn-rt-priv-a", "unicorn-rt-priv-b", "unicorn-rt-priv-c"]
  flow_log_name        = "unicorn-flow-log"
}

# ========== KMS ==========
module "KMS" {
  source             = "./modules/KMS"
  app_key_alias      = "alias/unicorn-kms-app"
  data_key_alias     = "alias/unicorn-kms-data"
  platform_key_alias = "alias/unicorn-kms-platform"
  rotation_period    = 90

  providers = {
    aws.us_east_1 = aws.us_east_1
  }
}

# ========== S3 ==========
module "S3" {
  source      = "./modules/S3"
  bucket_name = "unicorn-web-${data.aws_caller_identity.current.account_id}"
  kms_key_arn = module.KMS.data_key_arn
}

# ========== DynamoDB ==========
module "DynamoDB" {
  source         = "./modules/DynamoDB"
  table_name     = "unicorn-concert-db"
  kms_key_arn    = module.KMS.app_key_arn
  hash_key       = "booking_id"
  gsi_name       = "client-id-created-at-index"
  gsi_hash_key   = "client_id"
  gsi_range_key  = "created_at"
  gsi_projection = "ALL"
}

# ========== ECR ==========
module "ECR" {
  source          = "./modules/ECR"
  repository_name = "unicorn-concert-app"
  kms_key_arn     = module.KMS.data_key_arn
}

# ========== ECR Image Build & Push (done in CloudShell via apply.sh) ==========
# IMMUTABLE_WITH_EXCLUSION also set in apply.sh

# ========== EKS + K8s (manual via eksctl + kubectl) ==========
# 1. eksctl create cluster -f manifest/cluster.yaml
# 2. kubectl apply -f manifest/

# ========== EKS Pod Identity Role ==========
resource "aws_iam_role" "book_app" {
  name = "unicorn-book-app-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = "arn:aws:eks:ap-northeast-2:${data.aws_caller_identity.current.account_id}:cluster/unicorn-eks-cluster"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "book_app" {
  name = "unicorn-book-app-policy"
  role = aws_iam_role.book_app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query"]
        Resource = [module.DynamoDB.table_arn, "${module.DynamoDB.table_arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [module.KMS.app_key_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"]
        Resource = ["arn:aws:logs:ap-northeast-2:${data.aws_caller_identity.current.account_id}:*"]
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "book_app" {
  count           = 0 # Created after EKS exists
  cluster_name    = "unicorn-eks-cluster"
  namespace       = "unicorn"
  service_account = "unicorn-book-app-sa"
  role_arn        = aws_iam_role.book_app.arn
}

# ========== Lambda ==========
module "Lambda" {
  source             = "./modules/Lambda"
  function_name      = "unicorn-get-booking-func"
  kms_key_arn        = module.KMS.platform_key_arn
  table_name         = module.DynamoDB.table_name
  table_arn          = module.DynamoDB.table_arn
  log_group_name     = "/unicorn/lambda/get-booking"
  private_subnet_ids = module.VPC.private_subnet_ids
  vpc_id             = module.VPC.vpc_id
}

# ========== ALB ==========
module "ALB" {
  source             = "./modules/ALB"
  alb_name           = "unicorn-alb"
  tg_name            = "unicorn-tg"
  vpc_id             = module.VPC.vpc_id
  private_subnet_ids = module.VPC.private_subnet_ids
  lambda_arn         = module.Lambda.function_arn
  lambda_invoke_arn  = module.Lambda.invoke_arn
}

# ========== CloudFront + WAF ==========
module "CloudFront" {
  source               = "./modules/CloudFront"
  distribution_comment = "unicorn-svc-cf"
  s3_bucket_id         = module.S3.bucket_id
  s3_bucket_arn        = module.S3.bucket_arn
  alb_arn              = module.ALB.alb_arn
  alb_dns_name         = module.ALB.alb_dns_name
  waf_name             = "unicorn-waf"
  kms_key_arn          = module.KMS.platform_replica_key_arn
  vpc_id               = module.VPC.vpc_id
  alb_sg_id            = module.ALB.alb_sg_id
  private_subnet_ids   = module.VPC.private_subnet_ids

  providers = {
    aws.us_east_1 = aws.us_east_1
  }
}

# ========== IAM Audit Role ==========
module "IAM" {
  source             = "./modules/IAM"
  role_name          = "unicorn-audit-role"
  external_id        = "unicorn-audit-2026${var.number}"
  dynamodb_table_arn = module.DynamoDB.table_arn
  vpc_id             = module.VPC.vpc_id
  eks_cluster_arn    = "arn:aws:eks:ap-northeast-2:${data.aws_caller_identity.current.account_id}:cluster/unicorn-eks-cluster"
}

# ========== Grafana ALB ==========
resource "aws_lb" "grafana" {
  name               = "unicorn-grafana-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.grafana_alb.id]
  subnets            = module.VPC.public_subnet_ids

  tags = { Name = "unicorn-grafana-alb" }
}

resource "aws_security_group" "grafana_alb" {
  name   = "unicorn-grafana-alb-sg"
  vpc_id = module.VPC.vpc_id

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
  tags = { Name = "unicorn-grafana-alb-sg" }
}

resource "aws_lb_target_group" "grafana" {
  name        = "unicorn-grafana-tg"
  port        = 30300
  protocol    = "HTTP"
  vpc_id      = module.VPC.vpc_id
  target_type = "instance"

  health_check {
    path     = "/api/health"
    protocol = "HTTP"
    port     = "30300"
  }
  tags = { Name = "unicorn-grafana-tg" }
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

# ========== CloudWatch Log Groups ==========
resource "aws_cloudwatch_log_group" "book_app" {
  name       = "/unicorn/eks/book-app"
  kms_key_id = module.KMS.platform_key_arn
  tags       = { Name = "/unicorn/eks/book-app" }
}

# ========== Manifest S3 Bucket ==========
resource "aws_s3_bucket" "manifest" {
  bucket_prefix = "unicorn-manifest-"
  force_destroy = true
}

resource "aws_s3_object" "manifests" {
  for_each = fileset("${path.root}/manifest", "*")
  bucket   = aws_s3_bucket.manifest.id
  key      = each.value
  source   = "${path.root}/manifest/${each.value}"
  etag     = filemd5("${path.root}/manifest/${each.value}")
}

resource "aws_s3_object" "book_binary" {
  bucket = aws_s3_bucket.manifest.id
  key    = "book"
  source = "${path.root}/docker/book"
  etag   = filemd5("${path.root}/docker/book")
}

resource "aws_s3_object" "dockerfile" {
  bucket = aws_s3_bucket.manifest.id
  key    = "Dockerfile"
  source = "${path.root}/docker/Dockerfile"
  etag   = filemd5("${path.root}/docker/Dockerfile")
}

# ========== CloudShell VPC Environment ==========
# CloudShell VPC Environment must be created manually via AWS Console
# Name: unicorn-mark, Subnet: private subnet, SG: unicorn-mark-sg

resource "aws_security_group" "cloudshell" {
  name   = "unicorn-mark-sg"
  vpc_id = module.VPC.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "unicorn-mark-sg"
  }
}

# ========== CloudShell SG를 다른 SG들에서 모두 허용 ==========
# 채점 CloudShell(unicorn-mark)이 모든 리소스에 접근 가능해야 하므로
# 각 SG가 cloudshell SG를 source로 하는 전체 트래픽 ingress 를 허용한다.
resource "aws_security_group_rule" "vpce_from_cloudshell" {
  type                     = "ingress"
  security_group_id        = module.VPC.vpc_endpoint_sg_id
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.cloudshell.id
  description              = "Allow all from CloudShell (unicorn-mark)"
}

# ※ ALB SG 는 의도적으로 제외한다.
#   채점 8-5 (ALB Direct Request deny Test)는 CloudShell에서 ALB로 직접 요청 시
#   000/403 이 나와야 득점이므로, CloudShell을 ALB SG에 허용하면 200이 반환되어 감점된다.
#   ALB 는 CloudFront VPC Origin SG 에서만 허용한다(aws_security_group_rule.alb_from_cloudfront).

resource "aws_security_group_rule" "lambda_from_cloudshell" {
  type                     = "ingress"
  security_group_id        = module.Lambda.lambda_sg_id
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.cloudshell.id
  description              = "Allow all from CloudShell (unicorn-mark)"
}

resource "aws_security_group_rule" "grafana_alb_from_cloudshell" {
  type                     = "ingress"
  security_group_id        = aws_security_group.grafana_alb.id
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.cloudshell.id
  description              = "Allow all from CloudShell (unicorn-mark)"
}



# ========== EKS SG Rule (apply after EKS exists) ==========
# aws ec2 authorize-security-group-ingress --group-id <EKS_CLUSTER_SG> --protocol -1 --port -1 --source-group <cloudshell_sg_id>
# data "aws_eks_cluster" "this" {
#   name = "unicorn-eks-cluster"
# }
# resource "aws_security_group_rule" "eks_from_cloudshell" { ... }

# ========== ALB Ingress: CloudFront VPC Origin 전용 (과제지 10-1) ==========
# Internal ALB는 CloudFront를 거치지 않는 모든 요청(내부망 포함)을 거절해야 한다.
# VPC Origin 생성 시 CloudFront가 만드는 서비스 관리형 SG에서만 80을 허용한다.
data "aws_security_group" "cloudfront_vpc_origin" {
  filter {
    name   = "group-name"
    values = ["CloudFront-VPCOrigins-Service-SG*"]
  }

  depends_on = [module.CloudFront]
}

resource "aws_security_group_rule" "alb_from_cloudfront" {
  type                     = "ingress"
  security_group_id        = module.ALB.alb_sg_id
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = data.aws_security_group.cloudfront_vpc_origin.id
  description              = "Allow only CloudFront VPC origin (req 10-1)"
}


# ========== 비번호 전달 (terraform apply 입력값 -> apply.sh) ==========
# var.number 를 S3로 내려보내 apply.sh(Grafana 계정 skills<번호> 등)가 사용한다.
resource "aws_s3_object" "number" {
  bucket  = aws_s3_bucket.manifest.id
  key     = "number.env"
  content = "number=${var.number}\n"
}
