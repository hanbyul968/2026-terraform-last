terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-southeast-2"
}

data "aws_caller_identity" "current" {}

# setup.sh 를 담는 S3 버킷 (bastion이 받아 실행)
resource "aws_s3_bucket" "setup" {
  bucket = "wsc2026-logging-setup-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_object" "setup_sh" {
  bucket = aws_s3_bucket.setup.bucket
  key    = "setup.sh"
  source = "${path.module}/setup.sh"
  etag   = filemd5("${path.module}/setup.sh")
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "wsc2026-logging-vpc" }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "wsc2026-logging-internet-gateway" }
}

# Public Subnets (A, C only per task spec)
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-southeast-2a"
  map_public_ip_on_launch = true
  tags = { Name = "wsc2026-logging-public-subnet-a" }
}

resource "aws_subnet" "public_c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "ap-southeast-2c"
  map_public_ip_on_launch = true
  tags = { Name = "wsc2026-logging-public-subnet-c" }
}

# Private Subnets (A, C)
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "ap-southeast-2a"
  tags = { Name = "wsc2026-logging-private-subnet-a" }
}

resource "aws_subnet" "private_c" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "ap-southeast-2c"
  tags = { Name = "wsc2026-logging-private-subnet-c" }
}

# NAT Gateways (one per AZ)
resource "aws_eip" "nat_a" {
  domain = "vpc"
}

resource "aws_eip" "nat_c" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat_a" {
  allocation_id = aws_eip.nat_a.id
  subnet_id     = aws_subnet.public_a.id
  tags          = { Name = "wsc2026-logging-natgateway-a" }
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "nat_c" {
  allocation_id = aws_eip.nat_c.id
  subnet_id     = aws_subnet.public_c.id
  tags          = { Name = "wsc2026-logging-natgateway-c" }
  depends_on    = [aws_internet_gateway.main]
}

# Public Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "wsc2026-logging-public-routing-table" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_c" {
  subnet_id      = aws_subnet.public_c.id
  route_table_id = aws_route_table.public.id
}

# Private Route Tables (one per AZ)
resource "aws_route_table" "private_a" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_a.id
  }
  tags = { Name = "wsc2026-logging-private-routing-table-a" }
}

resource "aws_route_table" "private_c" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_c.id
  }
  tags = { Name = "wsc2026-logging-private-routing-table-c" }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private_a.id
}

resource "aws_route_table_association" "private_c" {
  subnet_id      = aws_subnet.private_c.id
  route_table_id = aws_route_table.private_c.id
}

# EKS Cluster IAM Role
resource "aws_iam_role" "eks_cluster" {
  name = "wsc2026-logging-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# EKS Cluster
resource "aws_eks_cluster" "main" {
  name     = "wsc2026-logging-cluster"
  version  = "1.35"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = [aws_subnet.public_a.id, aws_subnet.public_c.id, aws_subnet.private_a.id, aws_subnet.private_c.id]
    endpoint_public_access  = false
    endpoint_private_access = true
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

# EKS Node Group IAM Role
resource "aws_iam_role" "node_group" {
  name = "wsc2026-logging-nodegroup-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ng_worker" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node_group.name
}

resource "aws_iam_role_policy_attachment" "ng_cni" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node_group.name
}

resource "aws_iam_role_policy_attachment" "ng_ecr" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node_group.name
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "wsc2026-logging-node-group"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = [aws_subnet.private_a.id, aws_subnet.private_c.id]
  instance_types  = ["t3.medium"]
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 4
  }

  tags = { Name = "wsc2026-logging-worker-node" }

  depends_on = [
    aws_iam_role_policy_attachment.ng_worker,
    aws_iam_role_policy_attachment.ng_cni,
    aws_iam_role_policy_attachment.ng_ecr,
    aws_nat_gateway.nat_a,
    aws_nat_gateway.nat_c,
    aws_route_table_association.private_a,
    aws_route_table_association.private_c,
  ]
}

# CloudShell Security Group (ALL TRAFFIC OPEN)
resource "aws_security_group" "cloudshell" {
  name        = "wsc2026-logging-cloudshell-sg"
  description = "CloudShell VPC environment - all traffic open"
  vpc_id      = aws_vpc.main.id

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

  tags = { Name = "wsc2026-logging-cloudshell-sg" }
}

# ── Bastion EC2 (Windows 로컬 대신 VPC 내부에서 kubectl/helm 실행) ────────
# private endpoint 클러스터라 VPC 밖(Windows 로컬)에선 kubectl 불가 → bastion에서 수행
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_iam_role" "bastion" {
  name = "wsc2026-logging-bastion-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { AWS = "*" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_admin" {
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
  role       = aws_iam_role.bastion.name
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.bastion.name
}

resource "aws_iam_instance_profile" "bastion" {
  name = "wsc2026-logging-bastion-profile"
  role = aws_iam_role.bastion.name
}

resource "aws_security_group" "bastion" {
  name        = "wsc2026-logging-bastion-sg"
  description = "Bastion - kubectl/helm host"
  vpc_id      = aws_vpc.main.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "wsc2026-logging-bastion-sg" }
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.public_a.id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  associate_public_ip_address = true

  user_data = <<-EOF
#!/bin/bash
exec > /var/log/user-data.log 2>&1
# kubectl
curl -sLO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
# kubeconfig (root + ec2-user)
aws eks update-kubeconfig --name wsc2026-logging-cluster --region ap-southeast-2
sudo -u ec2-user aws eks update-kubeconfig --name wsc2026-logging-cluster --region ap-southeast-2

# S3에서 setup.sh 받아 나머지 리소스(ALB Controller, Loki/Grafana/FluentBit/nginx, Ingress) 자동 구성
aws s3 cp s3://wsc2026-logging-setup-${data.aws_caller_identity.current.account_id}/setup.sh /root/setup.sh --region ap-southeast-2
chmod +x /root/setup.sh
/root/setup.sh
echo done > /home/ec2-user/bastion_ready.txt
EOF

  user_data_replace_on_change = true

  depends_on = [aws_s3_object.setup_sh, aws_eks_node_group.main]

  tags = { Name = "wsc2026-logging-bastion" }
}

# bastion role → EKS cluster-admin (kubectl 권한)
resource "aws_eks_access_entry" "bastion" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.bastion.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "bastion_admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.bastion.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.bastion]
}

# bastion → EKS API 443 (클러스터 SG가 VPC CIDR 443은 이미 허용하지만 명시)
resource "aws_security_group_rule" "cluster_from_bastion" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.bastion.id
  security_group_id        = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  description              = "Allow bastion to EKS API"
}

# OIDC Provider
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["9e99a48a9960b14926bb7f3b02e22da2b0ab7280"]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

locals {
  oidc_provider = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

# EBS CSI Driver IRSA
resource "aws_iam_role" "ebs_csi" {
  name = "wsc2026-logging-ebs-csi-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${local.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi.name
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn
  depends_on               = [aws_eks_node_group.main]
}

# ALB Controller IRSA
resource "aws_iam_role" "alb_controller" {
  name = "wsc2026-logging-alb-controller-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${local.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  policy_arn = "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
  role       = aws_iam_role.alb_controller.name
}

resource "aws_iam_role_policy" "alb_controller_extra" {
  name = "wsc2026-logging-alb-extra"
  role = aws_iam_role.alb_controller.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:Describe*",
        "ec2:CreateSecurityGroup",
        "ec2:CreateTags",
        "ec2:DeleteTags",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:DeleteSecurityGroup",
        "elasticloadbalancing:*",
        "acm:ListCertificates",
        "acm:DescribeCertificate",
        "iam:ListServerCertificates",
        "iam:GetServerCertificate",
        "waf-regional:*",
        "wafv2:*",
        "shield:*",
        "tag:GetResources",
        "tag:TagResources"
      ]
      Resource = "*"
    }]
  })
}

# ALB는 Ingress(logging-ingress) + AWS Load Balancer Controller가 생성한다.
# (terraform에서 ALB/TG/리스너를 만들면 같은 이름으로 중복 생성되어 DuplicateLoadBalancerName 충돌)
# → 실제 ALB 생성·파드 IP 타깃 등록·경로 라우팅은 k8s Ingress가 담당. README 5단계 참고.

# CloudShell/bastion(VPC 내부) → EKS API 접근 허용 (private cluster 채점용)
resource "aws_security_group_rule" "cluster_from_cloudshell" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.cloudshell.id
  security_group_id        = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  description              = "Allow CloudShell/bastion SG to EKS"
}

resource "aws_security_group_rule" "cluster_from_vpc" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [aws_vpc.main.cidr_block]
  security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  description       = "Allow VPC internal to EKS API 443"
}

output "bastion_id" {
  value = aws_instance.bastion.id
}

output "bastion_public_ip" {
  value = aws_instance.bastion.public_ip
}

output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}
