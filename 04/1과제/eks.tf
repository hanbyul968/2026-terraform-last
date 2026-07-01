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
  vpc_id      = data.aws_vpc.this.id
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
    subnet_ids              = [data.aws_subnet.workload_a.id, data.aws_subnet.workload_c.id]
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

  # finalize(null_resource.private_only)가 CLI 로 endpoint_public_access 를 false 로 끈다.
  # 이후 root 재apply(예: bootstrap_egress=false phase)가 var.eks_public_access(기본 true)로
  # 되돌리면 채점 6-1-A(public=False) 가 깨지므로 endpoint 변경을 무시한다.
  lifecycle {
    ignore_changes = [vpc_config[0].endpoint_public_access]
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

# ── OIDC provider 제거 ──
#  04 는 IRSA 가 아니라 Pod Identity(aws_eks_pod_identity_association)를 사용하므로
#  OIDC provider 가 불필요하다. 게다가 fully-private 에서 'eks' 인터페이스 엔드포인트의
#  private DNS 가 eks.<region>.amazonaws.com 프라이빗 호스팅존을 만들어 그 하위인
#  oidc.eks.<region>.amazonaws.com 을 NXDOMAIN 으로 가려서 data.tls_certificate 가
#  "no such host" 로 실패한다. 따라서 OIDC provider/tls_certificate 를 제거한다.

# 채점 계정 principal -> ClusterAdmin (kubectl 채점용)
# principal_arn 에 data.aws_caller_identity.current.arn(=STS 세션 ARN)을 쓰면
# 'InvalidParameterException: principalArn format is not valid' 가 발생하므로,
# 별도 채점자 IAM Role/User ARN(var.grader_principal_arn)이 주어졌을 때만 생성한다.
# (Bastion 생성자가 이미 ClusterAdmin 이므로 기본 빈값=미생성이 정상)
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

# NOTE: Bastion(wsc-bastion-role)은 1단계(bastion 스테이지)로 이동했고, 그 Bastion 이
#   root(EKS)를 apply 하는 "클러스터 생성자"다. bootstrap_cluster_creator_admin_permissions
#   =true 와 위의 aws_eks_access_entry.admin(=생성자 caller identity) 으로 이미 ClusterAdmin 이므로,
#   별도의 bastion 전용 access entry 는 두지 않는다(동일 principal 중복 방지).

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
  # Pod Identity 자격증명은 파드 생성 시점에 주입된다. association 이 애드온보다 늦게
  # 만들어지면 controller 파드가 노드역할로 떠서 CrashLoop -> 애드온 20분 타임아웃.
  # 순서: pod-identity agent 애드온 -> association -> ebs_csi 애드온.
  depends_on = [aws_eks_node_group.addon, aws_eks_node_group.monitoring, aws_eks_pod_identity_association.ebs_csi]
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
  depends_on      = [aws_eks_addon.pod_identity]
}


# ── 노드 SSH(22) 허용 (채점 6-4: sshpass 로 노드 접속 후 ping/curl 실패 확인) ──
# 관리형 노드그룹은 클러스터 SG 를 노드에 붙이므로, 그 SG 에 VPC 내부 22 를 허용한다.
resource "aws_vpc_security_group_ingress_rule" "node_ssh" {
  security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = local.vpc_cidr
  description       = "SSH from VPC (grading 6-4)"
}
