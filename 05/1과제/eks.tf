############################
# EKS IAM Roles
############################

resource "aws_iam_role" "eks_cluster" {
  name = "gj2026-eks-cluster-role"
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

# 노드그룹별 별도 노드 role. role 을 분리해야 aws-auth 에서
# role 마다 다른 username(.addon.node / .app.node)을 매핑할 수 있다.
locals {
  node_roles = ["addon", "app"]
  node_managed_policies = [
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]
  # role × policy 평탄화 (for_each 용)
  node_role_policies = {
    for pair in setproduct(local.node_roles, local.node_managed_policies) :
    "${pair[0]}|${pair[1]}" => { role = pair[0], policy = pair[1] }
  }
}

resource "aws_iam_role" "eks_node" {
  for_each = toset(local.node_roles)
  name     = "gj2026-eks-${each.key}-node-role"
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
  role       = aws_iam_role.eks_node[each.value.role].name
  policy_arn = each.value.policy
}

# pull-through cache 첫 pull 시 노드가 직접 캐시 레포 생성/업스트림 임포트를
# 할 수 있어야 한다 (CloudShell 에서 선행 pull 하지 않은 이미지 대비).
# ecr-public/* 캐시 경로로 스코프.
resource "aws_iam_role_policy" "node_pull_through" {
  for_each = toset(local.node_roles)
  name     = "EcrPullThroughCache"
  role     = aws_iam_role.eks_node[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:CreateRepository", "ecr:BatchImportUpstreamImage"]
        Resource = "arn:aws:ecr:${local.region}:${local.account_id}:repository/ecr-public/*"
      }
    ]
  })
}

# 애플리케이션(app 노드그룹)만 DynamoDB/KMS 접근 필요.
resource "aws_iam_role_policy" "node_dynamodb_kms" {
  name = "DynamoDBBookAccess"
  role = aws_iam_role.eks_node["app"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
        Resource = [aws_dynamodb_table.books.arn, "${aws_dynamodb_table.books.arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = [aws_kms_key.dynamodb.arn]
      }
    ]
  })
}

############################
# EKS Cluster
############################

resource "aws_security_group_rule" "alb_to_nodes" {
  type                     = "ingress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_eks_cluster.cluster.vpc_config[0].cluster_security_group_id
}

resource "aws_security_group_rule" "alb_to_nodes_grafana" {
  type                     = "ingress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_eks_cluster.cluster.vpc_config[0].cluster_security_group_id
}

resource "aws_eks_cluster" "cluster" {
  name     = "gj2026-eks-cluster"
  version  = "1.35"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_group_ids      = [aws_security_group.eks_cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

############################
# OIDC Provider
############################

data "tls_certificate" "eks" {
  url = aws_eks_cluster.cluster.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.cluster.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
}

############################
# Book App IRSA
############################

resource "aws_iam_role" "book_app" {
  name = "gj2026-book-app-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:skills:book-sa"
          "${replace(aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "book_app_dynamodb" {
  name = "DynamoDBAccess"
  role = aws_iam_role.book_app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
        Resource = [aws_dynamodb_table.books.arn, "${aws_dynamodb_table.books.arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = [aws_kms_key.dynamodb.arn]
      }
    ]
  })
}

############################
# Grafana IRSA (CloudWatch read)
############################

resource "aws_iam_role" "grafana" {
  name = "gj2026-grafana-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:monitoring:grafana"
          "${replace(aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "grafana_cloudwatch" {
  role       = aws_iam_role.grafana.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

############################
# Launch Templates
############################

resource "aws_launch_template" "addon" {
  name = "gj2026-addon-node-lt"

  user_data = base64encode(<<-TOML
[settings.kubernetes]
server-tls-bootstrap = true

[settings.kubernetes.node-labels]
role = "addon"

[settings.bootstrap-containers.hostname-setter]
source = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com/gj2026-bootstrap:latest"
mode = "always"
essential = true
user-data = "YWRkb24="

[settings.host-containers.admin]
enabled = false
TOML
  )

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "gj2026-eks-addon-node" }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "gj2026-eks-addon-node" }
  }
}

resource "aws_launch_template" "app" {
  name = "gj2026-app-node-lt"

  user_data = base64encode(<<-TOML
[settings.kubernetes]
server-tls-bootstrap = true

[settings.kubernetes.node-labels]
role = "app"

[settings.bootstrap-containers.hostname-setter]
source = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com/gj2026-bootstrap:latest"
mode = "always"
essential = true
user-data = "YXBw"

[settings.host-containers.admin]
enabled = false
TOML
  )

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "gj2026-eks-app-node" }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "gj2026-eks-app-node" }
  }
}

############################
# Node Groups
############################

resource "aws_eks_node_group" "addon" {
  cluster_name    = aws_eks_cluster.cluster.name
  node_group_name = "gj2026-eks-addon-nodegroup"
  node_role_arn   = aws_iam_role.eks_node["addon"].arn
  subnet_ids      = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  instance_types  = ["t3.medium"]
  # LT 에 image_id 를 넣으면 amiType=CUSTOM 이 되어 채점(BOTTLEROCKET_x86_64 일치) 불통.
  ami_type = "BOTTLEROCKET_x86_64"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }

  labels = { role = "addon" }

  launch_template {
    id      = aws_launch_template.addon.id
    version = "$Latest"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_vpc_endpoint.interface,
    aws_vpc_endpoint.s3,
    aws_vpc_endpoint.dynamodb,
    aws_route_table_association.private_a,
    aws_route_table_association.private_b,
    null_resource.build_push_bootstrap,
    # 노드 join 전에 aws-auth 매핑이 존재해야 함
    kubernetes_config_map_v1.aws_auth,
  ]
}

resource "aws_eks_node_group" "app" {
  cluster_name    = aws_eks_cluster.cluster.name
  node_group_name = "gj2026-eks-app-nodegroup"
  node_role_arn   = aws_iam_role.eks_node["app"].arn
  subnet_ids      = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  instance_types  = ["m5.large"]
  ami_type        = "BOTTLEROCKET_x86_64"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }

  labels = { role = "app" }

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_vpc_endpoint.interface,
    aws_vpc_endpoint.s3,
    aws_vpc_endpoint.dynamodb,
    aws_route_table_association.private_a,
    aws_route_table_association.private_b,
    null_resource.build_push_bootstrap,
    kubernetes_config_map_v1.aws_auth,
  ]
}