# ═══════════════════════════════════════════════════════════════
# EKS Cluster  (과제 9.1)
#   - Name: wsc-eks-cluster / Version 1.35
#   - Control Plane 로그 전체 CloudWatch
#   - Secret = KMS(CMK) 암호화
#   - Public Access OFF / Private Access ON (채점 6-1-A)
#     * 단 apply 동안엔 var.eks_public_access=true 로 두고,
#       finalize.tf 가 마지막에 public 을 끈다.
#   - Workload Subnet 에서 운용
# ═══════════════════════════════════════════════════════════════

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

resource "aws_security_group" "eks_cluster" {
  name        = "wsc-eks-cluster-sg"
  description = "EKS cluster SG"
  vpc_id      = aws_vpc.this.id
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "wsc-eks-cluster-sg" }
}

resource "aws_eks_cluster" "this" {
  name     = local.cluster_name
  version  = "1.35"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = [aws_subnet.workload_a.id, aws_subnet.workload_c.id]
    security_group_ids      = [aws_security_group.eks_cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = var.eks_public_access
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

  # 변경: API 끄면(public off) state 가 매번 흔들리지 않게 endpoint 변경 무시 가능.
  # 여기서는 finalize 가 CLI 로 끄므로 무시하지 않는다.
  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

# ── OIDC (IRSA 대비) ──
data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
}

# 채점 계정 principal -> ClusterAdmin (kubectl 채점용)
resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = data.aws_caller_identity.current.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = data.aws_caller_identity.current.arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.admin]
}

# Bastion role -> ClusterAdmin (채점은 Bastion 에서 kubectl)
resource "aws_eks_access_entry" "bastion" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.bastion.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "bastion" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.bastion.arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.bastion]
}

# ═══════════════════════════════════════════════════════════════
# Addons
# ═══════════════════════════════════════════════════════════════
resource "aws_eks_addon" "pod_identity" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.addon]
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.addon, aws_eks_node_group.app, aws_eks_node_group.monitoring]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.addon]
}

# CoreDNS: addon 노드에 배치 + 클러스터 도메인 wsc.local (채점 6-6)
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  configuration_values = jsonencode({
    nodeSelector = { type = "addon" }
    corefile     = <<-EOF
      .:53 {
          errors
          health {
              lameduck 5s
          }
          ready
          kubernetes wsc.local in-addr.arpa ip6.arpa {
              pods insecure
              fallthrough in-addr.arpa ip6.arpa
              ttl 30
          }
          prometheus :9153
          forward . /etc/resolv.conf
          cache 30
          loop
          reload
          loadbalance
      }
    EOF
  })
  depends_on = [aws_eks_node_group.addon]
}

# EBS CSI Driver (PV 동적 프로비저닝, 과제 9.6)
resource "aws_iam_role" "ebs_csi" {
  name = "wsc-ebs-csi-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# CMK 로 볼륨 암호화 가능하도록 grant 허용
resource "aws_iam_role_policy" "ebs_csi_kms" {
  name = "EbsKms"
  role = aws_iam_role.ebs_csi.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"]
        Resource  = aws_kms_key.main.arn
        Condition = { Bool = { "kms:GrantIsForAWSResource" = "true" } }
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = aws_kms_key.main.arn
      }
    ]
  })
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.addon, aws_eks_node_group.monitoring]
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
  depends_on      = [aws_eks_addon.pod_identity]
}
