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
    Version = "2012-10-17"
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

  depends_on = [aws_iam_role_policy_attachment.m4_eks]
}

# Fargate Pod Execution Role
resource "aws_iam_role" "m4_fargate" {
  name = "skills-sqs-fargate-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "eks-fargate-pods.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "m4_fargate" {
  role       = aws_iam_role.m4_fargate.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
}

# Fargate Profiles
resource "aws_eks_fargate_profile" "m4_keda" {
  provider             = aws.oregon
  cluster_name         = aws_eks_cluster.m4.name
  fargate_profile_name = "skills-sqs-fp-keda"
  pod_execution_role_arn = aws_iam_role.m4_fargate.arn
  subnet_ids           = aws_subnet.m4_private[*].id
  selector { namespace = "keda" }
}

resource "aws_eks_fargate_profile" "m4_karpenter" {
  provider             = aws.oregon
  cluster_name         = aws_eks_cluster.m4.name
  fargate_profile_name = "skills-sqs-fp-karpenter"
  pod_execution_role_arn = aws_iam_role.m4_fargate.arn
  subnet_ids           = aws_subnet.m4_private[*].id
  selector { namespace = "karpenter" }
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
}

# IRSA: keda-operator
resource "aws_iam_role" "m4_keda" {
  name = "skills-sqs-keda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.m4.arn }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = { StringEquals = { "${local.oidc_issuer}:sub" = "system:serviceaccount:keda:keda-operator" } }
    }]
  })
}

resource "aws_iam_role_policy" "m4_keda" {
  name = "keda-sqs"
  role = aws_iam_role.m4_keda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = aws_sqs_queue.m4.arn }]
  })
}

# IRSA: karpenter
resource "aws_iam_role" "m4_karpenter" {
  name = "skills-sqs-karpenter-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.m4.arn }
      Action = "sts:AssumeRoleWithWebIdentity"
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
      { Effect = "Allow", Action = ["iam:PassRole"], Resource = "*" },
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
      Effect = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.m4.arn }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = { StringEquals = { "${local.oidc_issuer}:sub" = "system:serviceaccount:skills-sqs:sqs-worker-sa" } }
    }]
  })
}

resource "aws_iam_role_policy" "m4_worker" {
  name = "sqs-worker"
  role = aws_iam_role.m4_worker.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["sqs:*"], Resource = aws_sqs_queue.m4.arn }]
  })
}

# Karpenter Node Role
resource "aws_iam_role" "m4_node" {
  name = "skills-sqs-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
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

# Outputs
output "eks_cluster_name" { value = aws_eks_cluster.m4.name }
output "eks_endpoint" { value = aws_eks_cluster.m4.endpoint }
output "sqs_queue_url" { value = aws_sqs_queue.m4.url }
output "keda_role_arn" { value = aws_iam_role.m4_keda.arn }
output "karpenter_role_arn" { value = aws_iam_role.m4_karpenter.arn }
output "worker_role_arn" { value = aws_iam_role.m4_worker.arn }
output "node_role_arn" { value = aws_iam_role.m4_node.arn }
output "node_instance_profile" { value = aws_iam_instance_profile.m4_node.name }
