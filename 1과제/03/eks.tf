# ═══════════════════════════════════════════════════════════════
# EKS Cluster  (과제 7)
#   - Name: wsc2026-eks-cluster / Version 1.35
#   - Fully Private (public access OFF / private ON) -> 채점 4-1
#   - Control Plane 로그 전체 -> CloudWatch (eks-kms 암호화)
#   - Secret = CMK(wsc2026-eks-kms) 암호화
#   - 내부 도메인 wsc2026.skills.local (coredns)
#   - 노드는 app(private) 서브넷, IAM 최소권한
# ═══════════════════════════════════════════════════════════════

# 잠긴 wsc2026-eks-kms 키 정책은 '기존 wsc2026-eks-cluster-role' 에게만 grant 를 허용한다.
# 그 키를 재사용(data source)할 때는 역할도 재사용해야 클러스터 생성(grant)이 성공한다.
#   reuse_eks_cluster_role=true  -> 기존 역할 재사용(이 계정, 잠긴 키 재사용 시)
#   reuse_eks_cluster_role=false -> 역할 신규 생성(깨끗한 계정, 키를 새로 만드는 경우)
data "aws_iam_role" "eks_cluster_existing" {
  count = var.reuse_eks_cluster_role ? 1 : 0
  name  = "wsc2026-eks-cluster-role"
}

resource "aws_iam_role" "eks_cluster" {
  count = var.reuse_eks_cluster_role ? 0 : 1
  name  = "wsc2026-eks-cluster-role"
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
  count      = var.reuse_eks_cluster_role ? 0 : 1
  role       = aws_iam_role.eks_cluster[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

locals {
  eks_cluster_role_arn = var.reuse_eks_cluster_role ? data.aws_iam_role.eks_cluster_existing[0].arn : aws_iam_role.eks_cluster[0].arn
}

# Control Plane 로그 그룹 (CMK 암호화)
resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = 7
  kms_key_id        = local.kms_eks_arn
  tags              = { Name = "/aws/eks/${local.cluster_name}/cluster" }
}

# 추가 클러스터 SG (Any IP 금지 -> VPC 내부만)
resource "aws_security_group" "eks_cluster" {
  name        = "wsc2026-eks-cluster-extra-sg"
  description = "EKS cluster extra SG (VPC internal only)"
  vpc_id      = data.aws_vpc.this.id
  ingress {
    description = "VPC internal"
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
  tags = { Name = "wsc2026-eks-cluster-extra-sg" }
}

resource "aws_eks_cluster" "this" {
  name     = local.cluster_name
  version  = var.cluster_version
  role_arn = local.eks_cluster_role_arn

  vpc_config {
    subnet_ids              = [data.aws_subnet.app_a.id, data.aws_subnet.app_b.id]
    security_group_ids      = [aws_security_group.eks_cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = var.eks_public_access
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # EKS Secret는 항상 alias/wsc2026-eks-kms가 가리키는 관리 가능한 CMK로 암호화한다.
  encryption_config {
    provider {
      key_arn = local.kms_eks_arn
    }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster,
    aws_cloudwatch_log_group.eks,
  ]
}

# ── OIDC provider (보조) ──
data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
}

# 배포 주체(bastion 역할)는 이미 클러스터 생성자 admin 이므로 access entry 불필요.
# 채점(CloudShell) 신원은 var.grader_principal_arn(role/user ARN)으로 넘기면 생성.
# 비우면(기본) 생성 안 함. !! STS assumed-role 세션 ARN 은 사용 불가 !!
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
  depends_on                  = [aws_eks_node_group.addon, aws_eks_node_group.workload]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.addon]
}

# CoreDNS: addon 노드 배치 + 클러스터 도메인 wsc2026.skills.local
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  configuration_values = jsonencode({
    nodeSelector = { "wsc2026/node" = "addon" }
    corefile     = <<-EOF
      .:53 {
          errors
          health {
              lameduck 5s
          }
          ready
          kubernetes ${var.cluster_dns_domain} in-addr.arpa ip6.arpa {
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

# ── EBS CSI Driver (모니터링 PVC 동적 프로비저닝) ──
resource "aws_iam_role" "ebs_csi" {
  name = "wsc2026-ebs-csi-role"
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

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  configuration_values = jsonencode({
    controller = {
      nodeSelector = { "wsc2026/node" = "addon" }
    }
  })
  # ⚠ Pod Identity 자격증명은 파드 '생성 시점'에 주입된다. association 이 addon 보다 늦으면
  #   controller 파드가 노드 역할로 떠서 EC2 권한 없어 CrashLoop → addon 이 ACTIVE 안 됨.
  #   그래서 association 이후에 addon 을 만든다.
  depends_on = [aws_eks_node_group.addon, aws_eks_pod_identity_association.ebs_csi]
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
  depends_on      = [aws_eks_addon.pod_identity]
}
