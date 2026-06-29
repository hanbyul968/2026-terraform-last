terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

# 4-3 Container logging ??ap-northeast-1
provider "aws" {
  region = "ap-northeast-1"
}

data "aws_caller_identity" "current" {}

# ?Ä?Ä VPC (10.3.0.0/16) ?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä
resource "aws_vpc" "main" {
  cidr_block           = "10.3.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "wsc-logging-vpc" }
}
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "wsc-logging-igw" }
}
resource "aws_subnet" "pub_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.3.0.0/24"
  availability_zone       = "ap-northeast-1a"
  map_public_ip_on_launch = true
  tags = {
    Name                                        = "wsc-logging-sn-pub-a"
    "kubernetes.io/cluster/wsc-logging-cluster" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }
}
resource "aws_subnet" "pub_c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.3.1.0/24"
  availability_zone       = "ap-northeast-1c"
  map_public_ip_on_launch = true
  tags = {
    Name                                        = "wsc-logging-sn-pub-c"
    "kubernetes.io/cluster/wsc-logging-cluster" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }
}
resource "aws_subnet" "priv_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.3.2.0/24"
  availability_zone = "ap-northeast-1a"
  tags = {
    Name                                        = "wsc-logging-sn-priv-a"
    "kubernetes.io/cluster/wsc-logging-cluster" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }
}
resource "aws_subnet" "priv_c" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.3.3.0/24"
  availability_zone = "ap-northeast-1c"
  tags = {
    Name                                        = "wsc-logging-sn-priv-c"
    "kubernetes.io/cluster/wsc-logging-cluster" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }
}
resource "aws_eip" "nat" { domain = "vpc" }
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.pub_a.id
  tags          = { Name = "wsc-logging-nat" }
  depends_on    = [aws_internet_gateway.main]
}
resource "aws_route_table" "pub" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "wsc-logging-pub-rtb" }
}
resource "aws_route_table" "priv" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "wsc-logging-priv-rtb" }
}
resource "aws_route_table_association" "pub_a" {
  subnet_id      = aws_subnet.pub_a.id
  route_table_id = aws_route_table.pub.id
}
resource "aws_route_table_association" "pub_c" {
  subnet_id      = aws_subnet.pub_c.id
  route_table_id = aws_route_table.pub.id
}
resource "aws_route_table_association" "priv_a" {
  subnet_id      = aws_subnet.priv_a.id
  route_table_id = aws_route_table.priv.id
}
resource "aws_route_table_association" "priv_c" {
  subnet_id      = aws_subnet.priv_c.id
  route_table_id = aws_route_table.priv.id
}

# ?Ä?Ä EKS (wsc-logging-cluster v1.35) ?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä?Ä
resource "aws_iam_role" "eks_cluster" {
  name = "wsc-logging-cluster-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "eks.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}
resource "aws_eks_cluster" "main" {
  name     = "wsc-logging-cluster"
  version  = "1.35"
  role_arn = aws_iam_role.eks_cluster.arn
  vpc_config {
    subnet_ids              = [aws_subnet.pub_a.id, aws_subnet.pub_c.id, aws_subnet.priv_a.id, aws_subnet.priv_c.id]
    endpoint_public_access  = true
    endpoint_private_access = true
  }
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }
  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

resource "aws_iam_role" "node" {
  name = "wsc-logging-node-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy_attachment" "n_worker" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node.name
}
resource "aws_iam_role_policy_attachment" "n_cni" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node.name
}
resource "aws_iam_role_policy_attachment" "n_ecr" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node.name
}
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "wsc-logging-ng"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = [aws_subnet.priv_a.id, aws_subnet.priv_c.id]
  instance_types  = ["t3.medium"]
  ami_type        = "AL2023_x86_64_STANDARD"
  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }
  tags = { Name = "wsc-logging-node" }
  depends_on = [
    aws_iam_role_policy_attachment.n_worker,
    aws_iam_role_policy_attachment.n_cni,
    aws_iam_role_policy_attachment.n_ecr,
    aws_nat_gateway.main,
  ]
}

# ?Ä?Ä App EC2 (wsc-logging-app-bastion): docker flask wsc-log-app:5000 + Fluent Bit ?Ä?Ä
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
resource "aws_security_group" "app" {
  name   = "wsc-logging-app-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    description = "flask 5000"
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
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
  tags = { Name = "wsc-logging-app-sg" }
}
resource "aws_iam_role" "app" {
  name = "wsc-logging-app-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy_attachment" "app_ssm" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.app.name
}
resource "aws_iam_instance_profile" "app" {
  name = "wsc-logging-app-profile"
  role = aws_iam_role.app.name
}

# Î∞∞Ìè¨?åÏùº app.py / requirements.txt / Dockerfile Î•?app/ ???êÍ≥† Í∑∏Î?Î°??¨Ïö© (?òÏ†ï Í∏àÏ?).
# Loki NLB ?îÎìú?¨Ïù∏?∏Îäî EKS Î∞∞Ìè¨ ??Í∞ÄÎ≥Ä?¥Î?Î°? Fluent Bit ?§Ï†ï/?ÑÏª§ Í∏∞Îèô?Ä
# bastion deploy.sh(?êÎäî SSM)?êÏÑú LOKI_URL ??Î∞õÏïÑ ?òÌñâ?úÎã§. (manifest/app-setup.sh Ï∞∏Í≥†)
resource "aws_instance" "app" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.pub_a.id
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app.name
  associate_public_ip_address = true
  user_data                   = <<-EOF
    #!/bin/bash
    set -eux
    dnf install -y docker
    systemctl enable --now docker
    mkdir -p /opt/app
  EOF
  tags                        = { Name = "wsc-logging-app-bastion" }
}

output "cluster_name" { value = aws_eks_cluster.main.name }
output "cluster_endpoint" { value = aws_eks_cluster.main.endpoint }
output "app_ec2_id" { value = aws_instance.app.id }
output "app_public_ip" { value = aws_instance.app.public_ip }
