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

# ========== VPC ==========
module "VPC" {
  source                = "./modules/VPC"
  vpc_name              = "worldpay-vpc"
  vpc_cidr              = "10.0.0.0/16"
  public_subnets_cidr   = ["10.0.0.0/24", "10.0.1.0/24"]
  isolated_subnets_cidr = ["10.0.2.0/24", "10.0.3.0/24"]
  availability_zones    = ["ap-northeast-2a", "ap-northeast-2c"]
  public_subnet_names   = ["worldpay-public-subnet-a", "worldpay-public-subnet-c"]
  isolated_subnet_names = ["worldpay-isolated-subnet-a", "worldpay-isolated-subnet-c"]
}

# ========== KMS ==========
module "KMS" {
  source       = "./modules/KMS"
  db_key_alias = "alias/worldpay-db-key"
  s3_key_alias = "alias/worldpay-s3-key"
}

# ========== DynamoDB ==========
module "DynamoDB" {
  source      = "./modules/DynamoDB"
  table_name  = "Concerts"
  hash_key    = "booking_id"
  kms_key_arn = module.KMS.db_key_arn
}

# ========== S3 ==========
module "S3" {
  source      = "./modules/S3"
  bucket_name = "worldpay-bucket-${data.aws_caller_identity.current.account_id}"
  kms_key_arn = module.KMS.s3_key_arn
}

# ========== ECR ==========
module "ECR" {
  source          = "./modules/ECR"
  repository_name = "worldpay-book"
}

# ========== Bastion ==========
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_eip" "bastion" {
  domain = "vpc"
  tags   = { Name = "worldpay-bastion-eip" }
}

resource "aws_iam_role" "bastion" {
  name = "worldpay-bastion-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "worldpay-bastion-profile"
  role = aws_iam_role.bastion.name
}

resource "aws_security_group" "bastion" {
  name   = "worldpay-bastion-sg"
  vpc_id = module.VPC.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "worldpay-bastion-sg" }
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.small"
  subnet_id              = module.VPC.public_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.bastion.id]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name

  user_data = <<-EOF
    #!/bin/bash
    # Password auth
    echo 'ec2-user:worldpay2026!' | chpasswd
    sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
    systemctl restart sshd

    # Packages
    yum install -y curl jq unzip
    curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -qo /tmp/awscliv2.zip -d /tmp && /tmp/aws/install --update
    curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /usr/local/bin
  EOF

  tags = { Name = "worldpay-bastion" }
}

resource "aws_eip_association" "bastion" {
  instance_id   = aws_instance.bastion.id
  allocation_id = aws_eip.bastion.id
}

# ========== EKS Pod Identity Role ==========
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

# Pod Identity Association은 EKS 생성 후 setup.sh에서 관리

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
  tags = { Name = "book-alb-sg" }
}

resource "aws_lb" "book" {
  name               = "book-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.book_alb.id]
  subnets            = module.VPC.isolated_subnet_ids
  tags               = { Name = "book-alb" }
}

resource "aws_lb_target_group" "book" {
  name        = "book-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = module.VPC.vpc_id
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
  tags = { Name = "grafana-alb-sg" }
}

resource "aws_lb" "grafana" {
  name               = "grafana-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.grafana_alb.id]
  subnets            = module.VPC.public_subnet_ids
  tags               = { Name = "grafana-alb" }
}

resource "aws_lb_target_group" "grafana" {
  name        = "grafana-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = module.VPC.vpc_id
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

# ========== Manifest S3 Bucket ==========
resource "aws_s3_bucket" "manifest" {
  bucket_prefix = "worldpay-manifest-"
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
  source = "${path.root}/배포파일/book-linux-amd64_v1.0.1"
  etag   = filemd5("${path.root}/배포파일/book-linux-amd64_v1.0.1")
}

resource "aws_s3_object" "index_html" {
  bucket = aws_s3_bucket.manifest.id
  key    = "index.html"
  source = "${path.root}/배포파일/index.html"
  etag   = filemd5("${path.root}/배포파일/index.html")
}

resource "aws_s3_object" "main_jpeg" {
  bucket = aws_s3_bucket.manifest.id
  key    = "main.jpeg"
  source = "${path.root}/배포파일/main.jpeg"
  etag   = filemd5("${path.root}/배포파일/main.jpeg")
}

# ========== CloudFront ==========
module "CloudFront" {
  source                         = "./modules/CloudFront"
  distribution_name              = "worldpay-cdn"
  oac_name                       = "worldpay-s3-oac"
  s3_bucket_id                   = module.S3.bucket_id
  s3_bucket_arn                  = module.S3.bucket_arn
  s3_bucket_regional_domain_name = module.S3.bucket_regional_domain_name
  alb_dns_name                   = aws_lb.book.dns_name
  alb_arn                        = aws_lb.book.arn
}
