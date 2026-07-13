# ═══════════════════════════════════════════════════════════════
# EKS Cluster  (과제 8)
#   - Name: wskorea26-cluster / Version 1.35
#   - Control Plane 로그 전체 CloudWatch
#   - Secret = KMS(wskorea26-eks-key) 암호화
#   - Subnet: wskorea26-priv-subnet-c / -d (Private 환경)
#   - 외부에서 클러스터 API 접근 가능해야 함(채점 CloudShell):
#       endpoint public+private 모두 활성 + wskorea26-vpc-environment-sg
# 채점 5-1: name/version, 로그 5종, alias/wskorea26-eks-key, priv-subnet-c/-d
# ═══════════════════════════════════════════════════════════════

# 채점용 보안그룹 (과제 유의사항 13): 외부에서 EKS 에 접근
resource "aws_security_group" "vpc_environment" {
  name        = "wskorea26-vpc-environment-sg"
  description = "External access to EKS cluster API"
  vpc_id      = data.aws_vpc.this.id
  ingress {
    description = "EKS API from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "wskorea26-vpc-environment-sg" }
}

resource "aws_iam_role" "eks_cluster" {
  name = "wskorea26-eks-cluster-role"
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

resource "aws_eks_cluster" "this" {
  name     = local.cluster_name
  version  = var.eks_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = [data.aws_subnet.priv_c.id, data.aws_subnet.priv_d.id]
    security_group_ids      = [aws_security_group.vpc_environment.id]
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = ["0.0.0.0/0"]
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

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

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

# 채점 계정 principal -> ClusterAdmin (CloudShell kubectl 채점용)
#   주의: principal_arn 은 role/user ARN 이어야 한다(STS assumed-role 세션 ARN 불가).
#   bastion 에서 apply 시 data.aws_caller_identity 는 세션 ARN 이라 그대로 못 쓴다 →
#   채점 신원(예: arn:aws:iam::<acct>:user/<name>)을 var.grader_principal_arn 으로 넘긴다.
#   비우면(기본값) 생성 안 함 — 클러스터 생성자(apply 주체)는 이미 admin.
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

# ═══════════════════════════════════════════════════════════════
# Addons
# ═══════════════════════════════════════════════════════════════
# eks-pod-identity-agent 애드온 제거: 이 애드온 DaemonSet 은 app 노드에도 떠서
# 채점 5-3(kube-system 은 addon 노드만) 을 깨뜨린다. 애드온은 nodeSelector 설정을
# 지원하지 않으므로(스키마 비어있음), Pod Identity 대신 IRSA(OIDC) 로 전면 전환한다.
# (book/fluent-bit/lb-controller/ebs-csi 모두 IRSA)

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.addon, aws_eks_node_group.app]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.addon]
}

# CoreDNS: addon 노드에만 배치 (채점 5-3: kube-system pod 는 addon 노드)
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  configuration_values = jsonencode({
    nodeSelector = { "node-type" = "addon" }
  })
  depends_on = [aws_eks_node_group.addon]
}

# EBS CSI Driver (PV 동적 프로비저닝, 모니터링 스토리지)
resource "aws_iam_role" "ebs_csi" {
  name = "wskorea26-ebs-csi-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role_policy" "ebs_csi_kms" {
  name = "EbsKms"
  role = aws_iam_role.ebs_csi.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"]
        Resource  = aws_kms_key.s3.arn
        Condition = { Bool = { "kms:GrantIsForAWSResource" = "true" } }
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = aws_kms_key.s3.arn
      }
    ]
  })
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  # 컨트롤러/노드 데몬셋 모두 addon 노드에만 스케줄 → app 노드에 kube-system 파드 없음(채점 5-3)
  configuration_values = jsonencode({
    controller = { nodeSelector = { "node-type" = "addon" } }
    node       = { nodeSelector = { "node-type" = "addon" } }
  })
  depends_on = [aws_eks_node_group.addon, aws_iam_role_policy_attachment.ebs_csi]
}
