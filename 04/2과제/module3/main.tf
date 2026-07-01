terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

# 4-3 Container logging ??ap-northeast-1
provider "aws" {
  region = "ap-northeast-1"
}

variable "competitor_number" {
  description = "鍮꾨쾲????Grafana admin(wsc2026-admin-<踰덊샇> / admin<踰덊샇>!) ???ъ슜. deploy.sh 媛 -var 濡??꾨떖."
  type        = string
  default     = "00"
}

data "aws_caller_identity" "current" {}

# ?? VPC (10.3.0.0/16) ????????????????????????????????????????????????
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

# ?? EKS (wsc-logging-cluster v1.35) ??????????????????????????????????
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
  launch_template {
    id      = aws_launch_template.node.id
    version = "$Latest"
  }
  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 4
  }
  tags = { Name = "wsc-logging-node" }
  depends_on = [
    aws_iam_role_policy_attachment.n_worker,
    aws_iam_role_policy_attachment.n_cni,
    aws_iam_role_policy_attachment.n_ecr,
    aws_nat_gateway.main,
  ]
}

# ?? EBS CSI Driver (Loki PVC 10Gi gp3 bind ?? ???????????????????????
resource "aws_iam_role_policy_attachment" "n_ebs" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.node.name
}
resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.main, aws_iam_role_policy_attachment.n_ebs]
}

# ?? App EC2 (wsc-logging-app-bastion): docker flask wsc-log-app:5000 + Fluent Bit ??
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
# 而⑦뀒?대꼫 鍮뚮뱶/?ㅽ뻾 + helm(Loki/Grafana/LB controller) + EKS ?묎렐 + SSM ???꾪빐 Admin ?ъ슜
resource "aws_iam_role_policy_attachment" "app_admin" {
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
  role       = aws_iam_role.app.name
}
resource "aws_iam_instance_profile" "app" {
  name = "wsc-logging-app-profile"
  role = aws_iam_role.app.name
}

# app EC2 媛 kubectl/helm ?쇰줈 ?대윭?ㅽ꽣瑜??쒖뼱?????덈룄濡?cluster-admin access entry 遺??
resource "aws_eks_access_entry" "app" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.app.arn
  type          = "STANDARD"
}
resource "aws_eks_access_policy_association" "app_admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.app.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
  depends_on = [aws_eks_access_entry.app]
}

# ?? 諛고룷 ?꾪떚?⑺듃 S3 (app/ 諛고룷?뚯씪 + setup.sh + ec2-bootstrap.sh) ????
resource "aws_s3_bucket" "artifacts" {
  bucket        = "wsc-logging-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = { Name = "wsc-logging-artifacts" }
}
resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_object" "app_py" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "app/app.py"
  source = "${path.module}/app/app.py"
  etag   = filemd5("${path.module}/app/app.py")
}
resource "aws_s3_object" "app_req" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "app/requirements.txt"
  source = "${path.module}/app/requirements.txt"
  etag   = filemd5("${path.module}/app/requirements.txt")
}
resource "aws_s3_object" "app_docker" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "app/Dockerfile"
  source = "${path.module}/app/Dockerfile"
  etag   = filemd5("${path.module}/app/Dockerfile")
}
resource "aws_s3_object" "setup_sh" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "setup.sh"
  source = "${path.module}/setup.sh"
  etag   = filemd5("${path.module}/setup.sh")
}
resource "aws_s3_object" "ec2_bootstrap_sh" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "ec2-bootstrap.sh"
  source = "${path.module}/ec2-bootstrap.sh"
  etag   = filemd5("${path.module}/ec2-bootstrap.sh")
}

# 諛고룷?뚯씪 app.py/requirements.txt/Dockerfile 瑜?S3 濡?諛고룷?섍퀬, EC2 遺????
# ec2-bootstrap.sh 瑜??대젮諛쏆븘 ?ㅽ뻾?쒕떎(?꾩빱 鍮뚮뱶/?ㅽ뻾 + Loki/Grafana + Fluent Bit).
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
    export BUCKET=${aws_s3_bucket.artifacts.id}
    export SSM_PARAM=/wsc/module3/loki-endpoint
    export REGION=ap-northeast-1
    export CLUSTER=wsc-logging-cluster
    export NM=${var.competitor_number}
    dnf install -y unzip tar || true
    aws s3 cp "s3://$BUCKET/ec2-bootstrap.sh" /opt/ec2-bootstrap.sh --region "$REGION"
    chmod +x /opt/ec2-bootstrap.sh
    BUCKET="$BUCKET" SSM_PARAM="$SSM_PARAM" REGION="$REGION" CLUSTER="$CLUSTER" NM="$NM" bash /opt/ec2-bootstrap.sh
  EOF
  tags                        = { Name = "wsc-logging-app-bastion" }
  depends_on = [
    aws_s3_object.app_py, aws_s3_object.app_req, aws_s3_object.app_docker,
    aws_s3_object.setup_sh, aws_s3_object.ec2_bootstrap_sh,
    aws_eks_node_group.main, aws_eks_access_policy_association.app_admin,
  ]
}

output "artifacts_bucket" { value = aws_s3_bucket.artifacts.id }

output "cluster_name" { value = aws_eks_cluster.main.name }
output "cluster_endpoint" { value = aws_eks_cluster.main.endpoint }
output "app_ec2_id" { value = aws_instance.app.id }
output "app_public_ip" { value = aws_instance.app.public_ip }


# Launch template: IMDS hop limit 2 so in-cluster pods (EBS CSI controller) can
# reach IMDS and assume the node role. Without it the aws-ebs-csi-driver addon
# hangs in CREATING (controller CrashLoopBackOff: "no EC2 IMDS role found").
resource "aws_launch_template" "node" {
  name_prefix = "wsc-logging-ng-"
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "wsc-logging-node" }
  }
}


# Allow in-VPC clients (the app EC2 wsc-logging-app-bastion running setup.sh:
# kubectl/helm to deploy Loki/Grafana) to reach the EKS API server on 443.
# Without this the cluster security group blocks the app EC2 and kubectl hangs.
resource "aws_security_group_rule" "cluster_api_from_vpc" {
  description       = "In-VPC access to EKS API (app EC2 setup.sh)"
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [aws_vpc.main.cidr_block]
  security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}
