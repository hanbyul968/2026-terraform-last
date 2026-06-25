# ═══════════════════════════════════════════════════════════════
# EKS Managed Node Groups  (과제 8)
#   - wskorea26-addon-ng : label node-type=addon, 인스턴스 Name=wskorea26-addon-node
#   - wskorea26-app-ng   : label node-type=app,   인스턴스 Name=wskorea26-app-node
#   - 둘 다 t3.medium, priv-subnet-c/-d, 고가용성(desired 2)
#   - 볼륨 KMS(wskorea26-s3-key) 암호화 (Launch Template)
#   - node-type 라벨은 EKS managed nodegroup 의 labels 로 주입(채점 5-3)
# 채점 5-2: nodegroupName / t3.medium / tags.Name / priv-subnet-c,-d
# ═══════════════════════════════════════════════════════════════

locals {
  node_groups = {
    addon = { ng_name = "wskorea26-addon-ng", node_name = "wskorea26-addon-node", label = "addon" }
    app   = { ng_name = "wskorea26-app-ng", node_name = "wskorea26-app-node", label = "app" }
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

resource "aws_iam_role" "node" {
  for_each = local.node_groups
  name     = "wskorea26-${each.key}-node-role"
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

# 볼륨 KMS 암호화용 Launch Template (AMI/부트스트랩은 EKS managed 가 주입)
resource "aws_launch_template" "node" {
  for_each = local.node_groups
  name     = "wskorea26-${each.key}-node-lt"

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = aws_kms_key.s3.arn
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = each.value.node_name }
  }
  tag_specifications {
    resource_type = "volume"
    tags          = { Name = each.value.node_name }
  }
}

resource "aws_eks_node_group" "addon" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = local.node_groups.addon.ng_name
  node_role_arn   = aws_iam_role.node["addon"].arn
  subnet_ids      = [aws_subnet.priv_c.id, aws_subnet.priv_d.id]
  instance_types  = [var.node_instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }
  labels = { "node-type" = "addon" }

  launch_template {
    id      = aws_launch_template.node["addon"].id
    version = "$Latest"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_route_table_association.priv_c,
    aws_route_table_association.priv_d,
  ]
}

resource "aws_eks_node_group" "app" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = local.node_groups.app.ng_name
  node_role_arn   = aws_iam_role.node["app"].arn
  subnet_ids      = [aws_subnet.priv_c.id, aws_subnet.priv_d.id]
  instance_types  = [var.node_instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }
  labels = { "node-type" = "app" }

  launch_template {
    id      = aws_launch_template.node["app"].id
    version = "$Latest"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_route_table_association.priv_c,
    aws_route_table_association.priv_d,
  ]
}
