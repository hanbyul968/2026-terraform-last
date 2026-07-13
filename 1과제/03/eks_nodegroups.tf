# ═══════════════════════════════════════════════════════════════
# EKS Node Groups  (과제 7)
#   addon    : wsc2026-addon-nodegroup / node 이름 wsc2026-addon-node
#              label  wsc2026/node=addon
#   workload : wsc2026-workload-ng     / node 이름 wsc2026-workload-node
#              label  wsc2026/node=application
#   둘 다 t3.medium, app(private) 서브넷, desired 2 (고가용성, 채점 4-2)
#   IAM 은 최소 권한(Administrator 금지, 채점 4-3) -> 공용 node role
# ═══════════════════════════════════════════════════════════════

resource "aws_iam_role" "node" {
  name = "wsc2026-eks-node-role"
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
  for_each = toset([
    "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

locals {
  node_groups = {
    addon = {
      ng_name  = "wsc2026-addon-nodegroup"
      tag_name = "wsc2026-addon-node"
      label    = "addon"
    }
    workload = {
      ng_name  = "wsc2026-workload-ng"
      tag_name = "wsc2026-workload-node"
      label    = "application"
    }
  }
}

# 인스턴스 Name 태그 지정을 위한 Launch Template (bootstrap 은 EKS 가 자동 주입)
resource "aws_launch_template" "node" {
  for_each = local.node_groups
  name     = "wsc2026-${each.key}-node-lt"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = each.value.tag_name }
  }
  tag_specifications {
    resource_type = "volume"
    tags          = { Name = each.value.tag_name }
  }
}

resource "aws_eks_node_group" "addon" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = local.node_groups.addon.ng_name
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = [data.aws_subnet.app_a.id, data.aws_subnet.app_b.id]
  instance_types  = ["t3.medium"]
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }
  labels = { "wsc2026/node" = "addon" }

  launch_template {
    id      = aws_launch_template.node["addon"].id
    version = "$Latest"
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

resource "aws_eks_node_group" "workload" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = local.node_groups.workload.ng_name
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = [data.aws_subnet.app_a.id, data.aws_subnet.app_b.id]
  instance_types  = ["t3.medium"]
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }
  labels = { "wsc2026/node" = "application" }

  launch_template {
    id      = aws_launch_template.node["workload"].id
    version = "$Latest"
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}
