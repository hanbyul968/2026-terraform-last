terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

# 3-2 Keycloak SAML SSO — ap-northeast-2
provider "aws" {
  region = "ap-northeast-2"
}

# ── VPC ──────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "wsc2026-keycloak-vpc" }
}
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "wsc2026-keycloak-igw" }
}
resource "aws_subnet" "pub_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true
  tags                    = { Name = "wsc2026-public-subnet-a" }
}
resource "aws_subnet" "pub_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.2.0/24"
  availability_zone       = "ap-northeast-2c"
  map_public_ip_on_launch = true
  tags                    = { Name = "wsc2026-public-subnet-b" }
}
resource "aws_subnet" "priv_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.20.10.0/24"
  availability_zone = "ap-northeast-2a"
  tags              = { Name = "wsc2026-private-subnet-a" }
}
resource "aws_eip" "nat" { domain = "vpc" }
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.pub_a.id
  tags          = { Name = "wsc2026-keycloak-nat" }
  depends_on    = [aws_internet_gateway.main]
}
resource "aws_route_table" "pub" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "wsc2026-keycloak-pub-rtb" }
}
resource "aws_route_table" "priv" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "wsc2026-keycloak-priv-rtb" }
}
resource "aws_route_table_association" "pub_a" {
  subnet_id      = aws_subnet.pub_a.id
  route_table_id = aws_route_table.pub.id
}
resource "aws_route_table_association" "pub_b" {
  subnet_id      = aws_subnet.pub_b.id
  route_table_id = aws_route_table.pub.id
}
resource "aws_route_table_association" "priv_a" {
  subnet_id      = aws_subnet.priv_a.id
  route_table_id = aws_route_table.priv.id
}

# ── Security Groups ──────────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name   = "wsc2026-keycloak-alb-sg"
  vpc_id = aws_vpc.main.id
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
  tags = { Name = "wsc2026-keycloak-alb-sg" }
}
resource "aws_security_group" "keycloak" {
  name   = "wsc2026-keycloak-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    description     = "from ALB 8080"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "wsc2026-keycloak-sg" }
}

# ── EC2 (Keycloak, private, SSM) ─────────────────────────────────────
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
resource "aws_iam_role" "keycloak" {
  name = "wsc2026-keycloak-ec2-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy_attachment" "keycloak_ssm" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.keycloak.name
}
resource "aws_iam_instance_profile" "keycloak" {
  name = "wsc2026-keycloak-profile"
  role = aws_iam_role.keycloak.name
}
resource "aws_instance" "keycloak" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.priv_a.id
  vpc_security_group_ids = [aws_security_group.keycloak.id]
  iam_instance_profile   = aws_iam_instance_profile.keycloak.name
  user_data              = <<-EOF
    #!/bin/bash
    set -eux
    dnf install -y java-17-amazon-corretto
    cd /opt
    KC=keycloak-25.0.6
    curl -sL https://github.com/keycloak/keycloak/releases/download/25.0.6/$KC.tar.gz -o kc.tar.gz
    tar xzf kc.tar.gz && mv $KC keycloak
    export KEYCLOAK_ADMIN=admin
    export KEYCLOAK_ADMIN_PASSWORD='Skill53#!!@#'
    nohup /opt/keycloak/bin/kc.sh start-dev --http-port=8080 --proxy-headers=xforwarded --hostname-strict=false >/var/log/keycloak.log 2>&1 &
  EOF
  tags                   = { Name = "wsc2026-keycloak" }
}

# ── ALB ──────────────────────────────────────────────────────────────
resource "aws_lb" "main" {
  name               = "wsc2026-keycloak-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.pub_a.id, aws_subnet.pub_b.id]
}
resource "aws_lb_target_group" "main" {
  name        = "wsc2026-keycloak-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"
  health_check {
    path    = "/"
    matcher = "200-399"
  }
}
resource "aws_lb_target_group_attachment" "main" {
  target_group_arn = aws_lb_target_group.main.arn
  target_id        = aws_instance.keycloak.id
  port             = 8080
}
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

# ── SAML IdP + dev/infra Roles ───────────────────────────────────────
resource "aws_iam_saml_provider" "keycloak" {
  name                   = "wsc2026-keycloak-idp"
  saml_metadata_document = file("${path.module}/saml-metadata.xml")
}

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "dev" {
  name = "wsc2026-dev-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_saml_provider.keycloak.arn }
      Action    = "sts:AssumeRoleWithSAML"
      Condition = { StringEquals = { "SAML:aud" = "https://signin.aws.amazon.com/saml" } }
    }]
  })
}
resource "aws_iam_policy" "dev" {
  name = "wsc2026-dev-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["ec2:Describe*", "s3:Get*", "s3:List*"]
      Resource  = "*"
      Condition = { StringEquals = { "aws:RequestedRegion" = "ap-northeast-2" } }
    }]
  })
}
resource "aws_iam_role_policy_attachment" "dev" {
  role       = aws_iam_role.dev.name
  policy_arn = aws_iam_policy.dev.arn
}

resource "aws_iam_role" "infra" {
  name = "wsc2026-infra-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_saml_provider.keycloak.arn }
      Action    = "sts:AssumeRoleWithSAML"
      Condition = { StringEquals = { "SAML:aud" = "https://signin.aws.amazon.com/saml" } }
    }]
  })
}
resource "aws_iam_policy" "infra" {
  name = "wsc2026-infra-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "ReadAll", Effect = "Allow", Action = ["ec2:Describe*", "s3:Get*", "s3:List*", "iam:Get*", "iam:List*"], Resource = "*" },
      { Sid = "StartStop", Effect = "Allow", Action = ["ec2:StartInstances", "ec2:StopInstances"], Resource = "*",
      Condition = { StringNotEquals = { "ec2:ResourceTag/protected" = "true" } } }
    ]
  })
}
resource "aws_iam_role_policy_attachment" "infra" {
  role       = aws_iam_role.infra.name
  policy_arn = aws_iam_policy.infra.arn
}

output "keycloak_alb" { value = aws_lb.main.dns_name }
output "saml_provider_arn" { value = aws_iam_saml_provider.keycloak.arn }
