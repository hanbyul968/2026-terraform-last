###############################################################################
# Module 4: Event-driven Pod Scaling with SQS (us-west-2 Oregon)
###############################################################################

data "aws_availability_zones" "oregon" {
  provider = aws.oregon
  state    = "available"
}

# VPC
resource "aws_vpc" "m4" {
  provider             = aws.oregon
  cidr_block           = "10.4.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_subnet" "m4_public" {
  count                   = 2
  provider                = aws.oregon
  vpc_id                  = aws_vpc.m4.id
  cidr_block              = "10.4.${count.index}.0/24"
  availability_zone       = data.aws_availability_zones.oregon.names[count.index]
  map_public_ip_on_launch = true
}

resource "aws_subnet" "m4_private" {
  count             = 2
  provider          = aws.oregon
  vpc_id            = aws_vpc.m4.id
  cidr_block        = "10.4.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.oregon.names[count.index]
  tags = {
    "kubernetes.io/cluster/skills-sqs-cluster" = "owned"
  }
}

resource "aws_internet_gateway" "m4" {
  provider = aws.oregon
  vpc_id   = aws_vpc.m4.id
}

resource "aws_eip" "m4" {
  provider = aws.oregon
  domain   = "vpc"
}

resource "aws_nat_gateway" "m4" {
  provider      = aws.oregon
  allocation_id = aws_eip.m4.id
  subnet_id     = aws_subnet.m4_public[0].id
  depends_on    = [aws_internet_gateway.m4]
}

resource "aws_route_table" "m4_public" {
  provider = aws.oregon
  vpc_id   = aws_vpc.m4.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.m4.id
  }
}

resource "aws_route_table_association" "m4_public" {
  count          = 2
  provider       = aws.oregon
  subnet_id      = aws_subnet.m4_public[count.index].id
  route_table_id = aws_route_table.m4_public.id
}

resource "aws_route_table" "m4_private" {
  provider = aws.oregon
  vpc_id   = aws_vpc.m4.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.m4.id
  }
}

resource "aws_route_table_association" "m4_private" {
  count          = 2
  provider       = aws.oregon
  subnet_id      = aws_subnet.m4_private[count.index].id
  route_table_id = aws_route_table.m4_private.id
}

# EKS Cluster
resource "aws_iam_role" "m4_eks" {
  name = "skills-sqs-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "eks.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "m4_eks" {
  role       = aws_iam_role.m4_eks.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "m4" {
  provider = aws.oregon
  name     = "skills-sqs-cluster"
  role_arn = aws_iam_role.m4_eks.arn

  vpc_config {
    subnet_ids              = concat(aws_subnet.m4_public[*].id, aws_subnet.m4_private[*].id)
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  lifecycle {
    ignore_changes = [access_config]
  }

  depends_on = [aws_iam_role_policy_attachment.m4_eks]
}

resource "aws_ec2_tag" "m4_cluster_sg" {
  provider    = aws.oregon
  resource_id = aws_eks_cluster.m4.vpc_config[0].cluster_security_group_id
  key         = "kubernetes.io/cluster/skills-sqs-cluster"
  value       = "owned"
}

# Fargate Pod Execution Role
resource "aws_iam_role" "m4_fargate" {
  name = "skills-sqs-fargate-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "eks-fargate-pods.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "m4_fargate" {
  role       = aws_iam_role.m4_fargate.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
}

# Fargate Profiles
resource "aws_eks_fargate_profile" "m4_kube_system" {
  provider               = aws.oregon
  cluster_name           = aws_eks_cluster.m4.name
  fargate_profile_name   = "skills-sqs-fp-kube-system"
  pod_execution_role_arn = aws_iam_role.m4_fargate.arn
  subnet_ids             = aws_subnet.m4_private[*].id
  selector { namespace = "kube-system" }
}

resource "aws_eks_fargate_profile" "m4_keda" {
  provider               = aws.oregon
  cluster_name           = aws_eks_cluster.m4.name
  fargate_profile_name   = "skills-sqs-fp-keda"
  pod_execution_role_arn = aws_iam_role.m4_fargate.arn
  subnet_ids             = aws_subnet.m4_private[*].id
  selector { namespace = "keda" }
  depends_on = [aws_eks_fargate_profile.m4_kube_system]
}

resource "aws_eks_fargate_profile" "m4_karpenter" {
  provider               = aws.oregon
  cluster_name           = aws_eks_cluster.m4.name
  fargate_profile_name   = "skills-sqs-fp-karpenter"
  pod_execution_role_arn = aws_iam_role.m4_fargate.arn
  subnet_ids             = aws_subnet.m4_private[*].id
  selector { namespace = "karpenter" }
  depends_on = [aws_eks_fargate_profile.m4_keda]
}

# SQS Queue
resource "aws_sqs_queue" "m4" {
  provider                   = aws.oregon
  name                       = "skills-sqs-queue"
  visibility_timeout_seconds = 60
}

# OIDC Provider for IRSA
data "tls_certificate" "m4" {
  url = aws_eks_cluster.m4.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "m4" {
  url             = aws_eks_cluster.m4.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.m4.certificates[0].sha1_fingerprint]
}

locals {
  oidc_issuer = replace(aws_eks_cluster.m4.identity[0].oidc[0].issuer, "https://", "")

  # terraform을 실행한 주체(채점도 동일 주체)를 EKS access entry에 등록.
  # IAM User → 그대로 사용. Assumed Role(arn:aws:sts::...:assumed-role/ROLE/session) → role ARN으로 변환.
  caller_arn = data.aws_caller_identity.m4.arn
  admin_principal_arn = can(regex(":assumed-role/", local.caller_arn)) ? format(
    "arn:aws:iam::%s:role/%s",
    data.aws_caller_identity.m4.account_id,
    regex(":assumed-role/([^/]+)/", local.caller_arn)[0]
  ) : local.caller_arn
}

# IRSA: keda-operator
resource "aws_iam_role" "m4_keda" {
  name = "skills-sqs-keda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.m4.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = { StringEquals = { "${local.oidc_issuer}:sub" = "system:serviceaccount:keda:keda-operator" } }
    }]
  })
}

resource "aws_iam_role_policy" "m4_keda" {
  name = "keda-sqs"
  role = aws_iam_role.m4_keda.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = aws_sqs_queue.m4.arn }]
  })
}

# IRSA: karpenter
resource "aws_iam_role" "m4_karpenter" {
  name = "skills-sqs-karpenter-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.m4.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = { StringEquals = { "${local.oidc_issuer}:sub" = "system:serviceaccount:karpenter:karpenter" } }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "m4_karpenter_ec2" {
  role       = aws_iam_role.m4_karpenter.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

resource "aws_iam_role_policy_attachment" "m4_karpenter_ssm" {
  role       = aws_iam_role.m4_karpenter.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "m4_karpenter_eks" {
  role       = aws_iam_role.m4_karpenter.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy" "m4_karpenter_extra" {
  name = "karpenter-extra"
  role = aws_iam_role.m4_karpenter.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["eks:DescribeCluster"], Resource = aws_eks_cluster.m4.arn },
      { Effect = "Allow", Action = ["iam:PassRole", "iam:GetInstanceProfile", "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:TagInstanceProfile"], Resource = "*" },
      { Effect = "Allow", Action = ["pricing:*", "ec2:*", "ssm:GetParameter"], Resource = "*" }
    ]
  })
}

# IRSA: sqs-worker-sa
resource "aws_iam_role" "m4_worker" {
  name = "skills-sqs-worker-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.m4.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = { StringEquals = { "${local.oidc_issuer}:sub" = "system:serviceaccount:skills-sqs:sqs-worker-sa" } }
    }]
  })
}

resource "aws_iam_role_policy" "m4_worker" {
  name = "sqs-worker"
  role = aws_iam_role.m4_worker.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["sqs:*"], Resource = aws_sqs_queue.m4.arn }]
  })
}

# Karpenter Node Role
resource "aws_iam_role" "m4_node" {
  name = "skills-sqs-node-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "m4_node_worker" {
  role       = aws_iam_role.m4_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}
resource "aws_iam_role_policy_attachment" "m4_node_cni" {
  role       = aws_iam_role.m4_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}
resource "aws_iam_role_policy_attachment" "m4_node_ecr" {
  role       = aws_iam_role.m4_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
resource "aws_iam_role_policy_attachment" "m4_node_ssm" {
  role       = aws_iam_role.m4_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "m4_node" {
  name = "skills-sqs-node-profile"
  role = aws_iam_role.m4_node.name
}

resource "aws_eks_access_entry" "m4_node" {
  provider      = aws.oregon
  cluster_name  = aws_eks_cluster.m4.name
  principal_arn = aws_iam_role.m4_node.arn
  type          = "EC2_LINUX"
}

data "aws_caller_identity" "m4" {}

resource "aws_eks_access_entry" "m4_admin" {
  provider      = aws.oregon
  cluster_name  = aws_eks_cluster.m4.name
  principal_arn = local.admin_principal_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "m4_admin" {
  provider      = aws.oregon
  cluster_name  = aws_eks_cluster.m4.name
  principal_arn = local.admin_principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
  depends_on = [aws_eks_access_entry.m4_admin]
}

###############################################################################
# Bastion EC2 — EKS K8s 레이어(kubectl/helm/docker) 실행 호스트
# Windows에서 terraform apply만 하면, bastion이 CoreDNS 패치 + k8s-apply.sh를
# 자동 수행한다. (CloudShell/로컬 도구 불필요)
###############################################################################

data "aws_ami" "al2023_oregon" {
  provider    = aws.oregon
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_security_group" "m4_bastion" {
  provider    = aws.oregon
  vpc_id      = aws_vpc.m4.id
  description = "skills-sqs bastion (SSM only, no inbound)"
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "skills-sqs-bastion-sg" }
}

resource "aws_iam_role" "m4_bastion" {
  name = "skills-sqs-bastion-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "m4_bastion_ssm" {
  role       = aws_iam_role.m4_bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "m4_bastion_ecr" {
  role       = aws_iam_role.m4_bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"
}

resource "aws_iam_role_policy" "m4_bastion" {
  name = "skills-sqs-bastion-extra"
  role = aws_iam_role.m4_bastion.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["eks:DescribeCluster", "eks:ListClusters"], Resource = "*" },
      { Effect = "Allow", Action = ["ec2:DescribeSubnets", "ec2:CreateTags"], Resource = "*" },
      { Effect = "Allow", Action = ["iam:GetRole", "iam:GetInstanceProfile"], Resource = "*" },
      { Effect = "Allow", Action = ["sqs:GetQueueUrl", "sqs:GetQueueAttributes", "sqs:SendMessage"], Resource = aws_sqs_queue.m4.arn }
    ]
  })
}

resource "aws_iam_instance_profile" "m4_bastion" {
  name = "skills-sqs-bastion-profile"
  role = aws_iam_role.m4_bastion.name
}

# Bastion을 EKS cluster-admin으로 등록 (kubectl/helm 실행 권한)
resource "aws_eks_access_entry" "m4_bastion" {
  provider      = aws.oregon
  cluster_name  = aws_eks_cluster.m4.name
  principal_arn = aws_iam_role.m4_bastion.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "m4_bastion" {
  provider      = aws.oregon
  cluster_name  = aws_eks_cluster.m4.name
  principal_arn = aws_iam_role.m4_bastion.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
  depends_on = [aws_eks_access_entry.m4_bastion]
}

resource "aws_instance" "m4_bastion" {
  provider                    = aws.oregon
  ami                         = data.aws_ami.al2023_oregon.id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.m4_public[0].id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.m4_bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.m4_bastion.name

  user_data = <<-USERDATA
#!/bin/bash
set -ex
exec > /var/log/skills-bastion-bootstrap.log 2>&1
REGION=us-west-2
CLUSTER=skills-sqs-cluster

dnf install -y docker git
systemctl enable --now docker

# kubectl (클러스터 버전에 맞춰)
EKS_VER=$(aws eks describe-cluster --region $REGION --name $CLUSTER --query cluster.version --output text)
curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/v$${EKS_VER}.0/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# 클러스터가 ACTIVE 될 때까지 대기
until [ "$(aws eks describe-cluster --region $REGION --name $CLUSTER --query cluster.status --output text)" = "ACTIVE" ]; do sleep 15; done

# repo clone 후 K8s 레이어 배포 (CoreDNS 패치 포함)
cd /root
git clone https://github.com/hnmly/2026-terraform.git
cd 2026-terraform/07/2과제
bash k8s-apply.sh
echo "BASTION_BOOTSTRAP_DONE"
USERDATA

  tags = { Name = "skills-sqs-bastion" }
  depends_on = [
    aws_eks_fargate_profile.m4_karpenter,
    aws_eks_access_policy_association.m4_bastion,
    aws_nat_gateway.m4
  ]
}

# Outputs
output "eks_cluster_name" { value = aws_eks_cluster.m4.name }
output "eks_endpoint" { value = aws_eks_cluster.m4.endpoint }
output "sqs_queue_url" { value = aws_sqs_queue.m4.url }
output "bastion_instance_id" { value = aws_instance.m4_bastion.id }
output "bastion_public_ip" { value = aws_instance.m4_bastion.public_ip }
