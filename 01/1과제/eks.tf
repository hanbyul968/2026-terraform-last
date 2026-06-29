############################
# EKS Cluster IAM role
############################
resource "aws_iam_role" "eks_cluster" {
  name = "wsc-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

############################
# Node IAM roles (app, addon)
############################
locals {
  node_roles = ["app", "addon"]
  node_managed_policies = [
    "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]
  node_role_policies = {
    for pair in setproduct(local.node_roles, local.node_managed_policies) :
    "${pair[0]}|${pair[1]}" => { role = pair[0], policy = pair[1] }
  }
}

resource "aws_iam_role" "node" {
  for_each = toset(local.node_roles)
  name     = "wsc-eks-${each.key}-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each   = local.node_role_policies
  role       = aws_iam_role.node[each.value.role].name
  policy_arn = each.value.policy
}

# KMS 암호화된 ECR 이미지 pull 을 위해 노드에 kms:Decrypt 허용
resource "aws_iam_role_policy" "node_kms" {
  for_each = toset(local.node_roles)
  name     = "EcrKmsDecrypt"
  role     = aws_iam_role.node[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:Decrypt", "kms:DescribeKey"]
      Resource = aws_kms_key.main.arn
    }]
  })
}

############################
# EKS Cluster
#   apply 동안엔 public+private (Windows 에서 k8s/helm 적용 위해).
#   finalize.tf 에서 마지막에 public 을 끈다.
############################
resource "aws_eks_cluster" "this" {
  name     = local.cluster_name
  version  = "1.35"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = [aws_subnet.priv_a.id, aws_subnet.priv_b.id]
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.main.arn
    }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

############################
# OIDC provider (for completeness / future IRSA)
############################
data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
}

############################
# Access entry: 채점 principal -> ClusterAdmin (옵션)
#   - bastion(클러스터 생성자)은 bootstrap_cluster_creator_admin_permissions 로 이미 admin.
#   - 채점은 별도 principal(CloudShell)이므로, 그 ARN 을 var.grader_principal_arn 으로 주면 생성.
#     (assumed-role 세션 ARN 이 아니라 역할/사용자 ARN 을 사용할 것)
############################
resource "aws_eks_access_entry" "admin" {
  count         = var.grader_principal_arn == "" ? 0 : 1
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.grader_principal_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  count         = var.grader_principal_arn == "" ? 0 : 1
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.grader_principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}

############################
# Launch templates (instance Name tags)
############################
resource "aws_launch_template" "app" {
  name = "wsc-app-node-lt"
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "wsc-app-node" }
  }
  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "wsc-app-node" }
  }
}

resource "aws_launch_template" "addon" {
  name = "wsc-addon-node-lt"
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "wsc-addon-node" }
  }
  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "wsc-addon-node" }
  }
}

############################
# Node groups
############################
resource "aws_eks_node_group" "app" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "wsc-app-nodegroup"
  node_role_arn   = aws_iam_role.node["app"].arn
  subnet_ids      = [aws_subnet.priv_a.id, aws_subnet.priv_b.id]
  instance_types  = ["t3.medium"]
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }

  labels = {
    node                             = "app"
    "alpha.eksctl.io/nodegroup-name" = "wsc-app-nodegroup"
  }

  # app 노드엔 book 만 스케줄되도록 taint
  taint {
    key    = "node"
    value  = "app"
    effect = "NO_SCHEDULE"
  }

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_route_table_association.priv_a,
    aws_route_table_association.priv_b,
    aws_nat_gateway.a,
    aws_nat_gateway.b,
  ]
}

resource "aws_eks_node_group" "addon" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "wsc-addon-nodegroup"
  node_role_arn   = aws_iam_role.node["addon"].arn
  subnet_ids      = [aws_subnet.priv_a.id, aws_subnet.priv_b.id]
  instance_types  = ["t3.medium"]
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }

  labels = {
    node                             = "addon"
    "alpha.eksctl.io/nodegroup-name" = "wsc-addon-nodegroup"
  }

  launch_template {
    id      = aws_launch_template.addon.id
    version = "$Latest"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_route_table_association.priv_a,
    aws_route_table_association.priv_b,
    aws_nat_gateway.a,
    aws_nat_gateway.b,
  ]
}

############################
# EKS Addons
############################
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.app, aws_eks_node_group.addon]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.app, aws_eks_node_group.addon]
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  # coredns 는 addon 노드에서 구동
  configuration_values = jsonencode({
    nodeSelector = { node = "addon" }
  })
  depends_on = [aws_eks_node_group.addon]
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.app, aws_eks_node_group.addon]
}

############################
# Book app Pod Identity (DynamoDB access)
############################
resource "aws_iam_role" "book_app" {
  name = "wsc-book-app-role"
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
  name = "DynamoDBAccess"
  role = aws_iam_role.book_app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:Query",
        "dynamodb:Scan",
        "dynamodb:UpdateItem",
        "dynamodb:DescribeTable"
      ]
      Resource = [aws_dynamodb_table.wsc.arn, "${aws_dynamodb_table.wsc.arn}/index/*"]
    }]
  })
}

resource "aws_eks_pod_identity_association" "book" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "book"
  service_account = "book-sa"
  role_arn        = aws_iam_role.book_app.arn

  depends_on = [aws_eks_addon.pod_identity]
}
