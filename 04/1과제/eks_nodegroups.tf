# ═══════════════════════════════════════════════════════════════
# EKS Node Groups  (과제 9.2)
#   - app / addon / monitoring  (모두 Managed, AL2023, t3.medium)
#   - Workload Subnet, 최소 고가용성(desired 2, 2 AZ)
#   - Label  { type: app | addon | monitoring }
#   - Instance Name Tag  wsc-app-node | wsc-addon-node | wsc-monitoring-node
#   - 볼륨 KMS(CMK) 암호화 (채점 6-3)
#   - hostname = i-<id>.ap-northeast-2.compute.internal
#       => workload 서브넷 private_dns_hostname_type_on_launch=resource-name 로 처리
#   - 클러스터 도메인 wsc.local  / SSH password Skill53##  => nodeadm user_data
#   - app 노드: IMDS hop limit 1 => Pod 가 IMDS 접근 불가 (채점 6-5)
# ═══════════════════════════════════════════════════════════════

locals {
  node_groups = {
    app        = { name = "wsc-app-ng", tag = "wsc-app-node", label = "app", imds_hop = 1 }
    addon      = { name = "wsc-addon-ng", tag = "wsc-addon-node", label = "addon", imds_hop = 2 }
    monitoring = { name = "wsc-monitoring-ng", tag = "wsc-monitoring-node", label = "monitoring", imds_hop = 2 }
  }

  node_managed_policies = [
    "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]
  node_role_policies = {
    for pair in setproduct(keys(local.node_groups), local.node_managed_policies) :
    "${pair[0]}|${pair[1]}" => { role = pair[0], policy = pair[1] }
  }
}

# 노드그룹별 별도 IAM Role
resource "aws_iam_role" "node" {
  for_each = local.node_groups
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

# KMS 암호화 ECR 이미지 pull / pull-through cache 생성 허용
resource "aws_iam_role_policy" "node_extra" {
  for_each = local.node_groups
  name     = "EcrKmsPullThrough"
  role     = aws_iam_role.node[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = aws_kms_key.main.arn
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:CreateRepository", "ecr:BatchImportUpstreamImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage", "ecr:GetAuthorizationToken"]
        Resource = "*"
      }
    ]
  })
}

# 서비스 IPv4 CIDR (nodeadm 에 필요)
data "aws_eks_cluster" "this" {
  name = aws_eks_cluster.this.name
}

# ── Launch Templates (노드그룹별) ──
resource "aws_launch_template" "node" {
  for_each = local.node_groups
  name     = "wsc-${each.key}-node-lt"

  user_data = base64encode(templatefile("${path.module}/files/nodeadm.mime.tftpl", {
    cluster_name       = aws_eks_cluster.this.name
    endpoint           = aws_eks_cluster.this.endpoint
    ca                 = aws_eks_cluster.this.certificate_authority[0].data
    service_cidr       = data.aws_eks_cluster.this.kubernetes_network_config[0].service_ipv4_cidr
    cluster_dns_domain = var.cluster_dns_domain
    label              = each.value.label
    ssh_password       = var.ssh_password
  }))

  # 볼륨 KMS 암호화
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = aws_kms_key.main.arn
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = each.value.imds_hop
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = each.value.tag }
  }
  tag_specifications {
    resource_type = "volume"
    tags          = { Name = each.value.tag }
  }
}

resource "aws_eks_node_group" "app" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = local.node_groups.app.name
  node_role_arn   = aws_iam_role.node["app"].arn
  subnet_ids      = [aws_subnet.workload_a.id, aws_subnet.workload_c.id]
  instance_types  = ["t3.medium"]
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }
  labels = { type = "app" }

  launch_template {
    id      = aws_launch_template.node["app"].id
    version = "$Latest"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_vpc_endpoint.interface,
    aws_route_table_association.workload_a,
    aws_route_table_association.workload_c,
  ]
}

resource "aws_eks_node_group" "addon" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = local.node_groups.addon.name
  node_role_arn   = aws_iam_role.node["addon"].arn
  subnet_ids      = [aws_subnet.workload_a.id, aws_subnet.workload_c.id]
  instance_types  = ["t3.medium"]
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }
  labels = { type = "addon" }

  launch_template {
    id      = aws_launch_template.node["addon"].id
    version = "$Latest"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_vpc_endpoint.interface,
    aws_route_table_association.workload_a,
    aws_route_table_association.workload_c,
  ]
}

resource "aws_eks_node_group" "monitoring" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = local.node_groups.monitoring.name
  node_role_arn   = aws_iam_role.node["monitoring"].arn
  subnet_ids      = [aws_subnet.workload_a.id, aws_subnet.workload_c.id]
  instance_types  = ["t3.medium"]
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }
  labels = { type = "monitoring" }

  launch_template {
    id      = aws_launch_template.node["monitoring"].id
    version = "$Latest"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_vpc_endpoint.interface,
    aws_route_table_association.workload_a,
    aws_route_table_association.workload_c,
  ]
}
