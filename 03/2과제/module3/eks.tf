# =============================================================================
# EKS Cluster (v1.35, PUBLIC endpoint) + 관리형 노드그룹 (private subnet, x2)
# =============================================================================

# ---- EKS Cluster IAM Role ----
resource "aws_iam_role" "eks_cluster" {
  name = "wsc2026-logging-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---- EKS Cluster (퍼블릭 접근) ----
resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = "1.35"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids = [
      aws_subnet.public_a.id,
      aws_subnet.public_c.id,
      aws_subnet.private_a.id,
      aws_subnet.private_c.id,
    ]
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
  tags       = { Name = local.cluster_name }
}

# ---- Node Group IAM Role ----
resource "aws_iam_role" "node" {
  name = "wsc2026-logging-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}
resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}
resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ---- 관리형 노드그룹 (AL2023, t3.medium x2, private subnet) ----
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "wsc2026-logging-nodegroup"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = [aws_subnet.private_a.id, aws_subnet.private_c.id]
  instance_types  = ["t3.medium"]
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 2
  }

  update_config {
    max_unavailable = 1
  }

  tags = { Name = "wsc2026-logging-nodegroup" }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
    aws_route_table_association.private_a,
    aws_route_table_association.private_c,
  ]
}

# ---- EKS Addons ----
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"
  depends_on   = [aws_eks_node_group.main]
}
resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"
  depends_on   = [aws_eks_node_group.main]
}
resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"
  depends_on   = [aws_eks_node_group.main]
}

# ---- OIDC Provider (IRSA, LB controller 등 확장 대비) ----
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# ---- 채점 주체(CloudShell)에 Cluster Admin access entry 부여 ----
locals {
  caller_arn = data.aws_caller_identity.current.arn
  grader_principal_arn = can(regex(":assumed-role/", local.caller_arn)) ? format(
    "arn:aws:iam::%s:role/%s",
    data.aws_caller_identity.current.account_id,
    element(split("/", local.caller_arn), 1)
  ) : local.caller_arn
}
