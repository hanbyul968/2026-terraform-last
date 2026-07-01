terraform {
  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 6.0" }
    null = { source = "hashicorp/null", version = "~> 3.0" }
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
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }
  user_data = templatefile("${path.module}/userdata.sh.tpl", {
    admin_password = "Skill53#!!@#"
    realm          = "wsc2026-aws"
    account_id     = data.aws_caller_identity.current.account_id
    saml_provider  = "wsc2026-keycloak-idp"
    dev_role       = "wsc2026-dev-role"
    infra_role     = "wsc2026-infra-role"
    dev_user_pw    = "Skills_dev53%$%"
    infra_user_pw  = "Skills_infra53#@#"
  })
  tags = { Name = "wsc2026-keycloak" }
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
# Keycloak Realm 의 SAML 메타데이터는 EC2(userdata.sh.tpl)로 Keycloak/Realm 기동
# 후에야 존재하므로, IAM SAML Provider(wsc2026-keycloak-idp) 와 Role(dev/infra)은
# saml-iam.sh 를 local-exec(apply 시, bastion 리눅스)로 실행하여 실제 descriptor 로
# 등록한다. 관리형 정책(dev/infra)만 terraform 이 관리하고 그 ARN 을 스크립트에 전달.
data "aws_caller_identity" "current" {}

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

# Keycloak 기동(Realm/SAML Client 생성) 후 실제 SAML descriptor 로 IAM SAML Provider +
# dev/infra Role 생성 및 정책 연결. (apply 는 bastion 리눅스에서 수행)
resource "null_resource" "saml_iam" {
  triggers = {
    alb          = aws_lb.main.dns_name
    dev_policy   = aws_iam_policy.dev.arn
    infra_policy = aws_iam_policy.infra.arn
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = join(" ", [
      "bash",
      "${path.module}/saml-iam.sh",
      "'${aws_lb.main.dns_name}'",
      "'${data.aws_caller_identity.current.account_id}'",
      "'${aws_iam_policy.dev.arn}'",
      "'${aws_iam_policy.infra.arn}'",
      "'ap-northeast-2'",
      "'wsc2026-keycloak-idp'",
      "'wsc2026-dev-role'",
      "'wsc2026-infra-role'",
    ])
  }

  depends_on = [
    aws_lb_listener.http,
    aws_lb_target_group_attachment.main,
    aws_instance.keycloak,
    aws_iam_policy.dev,
    aws_iam_policy.infra,
  ]
}

output "keycloak_alb" { value = aws_lb.main.dns_name }
output "saml_provider_name" { value = "wsc2026-keycloak-idp" }
output "login_url" {
  value = "http://${aws_lb.main.dns_name}/realms/wsc2026-aws/protocol/saml/clients/amazon-aws"
}
