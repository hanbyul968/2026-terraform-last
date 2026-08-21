# Karpenter — fast node autoscaling for traffic bursts.
# Managed node group stays as the stable baseline (runs Karpenter itself);
# Karpenter provisions extra capacity on demand (same instance type as the
# node group unless karpenter_instance_types overrides it) and consolidates
# it away when idle (cost ratio scoring).

locals {
  # Karpenter가 고를 타입. 지정이 없으면 관리형 NG와 같은 타입을 쓴다 —
  # 두 곳이 갈리면 노드마다 용량이 달라져 bin-packing 예측과 비용 환산이 모두 틀어진다.
  karpenter_instance_types = length(var.karpenter_instance_types) > 0 ? var.karpenter_instance_types : [var.node_instance_type]

  # k8s 1.35 requires Karpenter >= 1.9 (compatibility matrix). 1.13.x covers 1.35/1.36.
  karpenter_version = "1.13.0"
}

# ----- Node role for Karpenter-launched instances -----
resource "aws_iam_role" "karpenter_node" {
  name = "${local.name}-karpenter-node"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])
  role       = aws_iam_role.karpenter_node.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${local.name}-karpenter-node"
  role = aws_iam_role.karpenter_node.name
}

# Let Karpenter nodes join the cluster (API auth mode)
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"
}

# ----- Controller IRSA -----
data "aws_iam_policy_document" "karpenter_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:sub"
      values   = ["system:serviceaccount:kube-system:karpenter"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_controller" {
  name               = "${local.name}-karpenter-controller"
  assume_role_policy = data.aws_iam_policy_document.karpenter_assume.json
}

resource "aws_iam_role_policy" "karpenter_controller" {
  name = "${local.name}-karpenter-controller"
  role = aws_iam_role.karpenter_controller.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Compute"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances", "ec2:CreateFleet", "ec2:CreateLaunchTemplate",
          "ec2:CreateTags", "ec2:TerminateInstances", "ec2:DeleteLaunchTemplate",
          "ec2:DescribeAvailabilityZones", "ec2:DescribeImages",
          "ec2:DescribeInstances", "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes", "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups", "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets"
        ]
        Resource = "*"
      },
      {
        Sid      = "Pricing"
        Effect   = "Allow"
        Action   = ["pricing:GetProducts"]
        Resource = "*"
      },
      {
        Sid      = "SSM"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:*:*:parameter/aws/service/*"
      },
      {
        Sid      = "PassNodeRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = aws_iam_role.karpenter_node.arn
      },
      {
        Sid    = "InstanceProfile"
        Effect = "Allow"
        Action = [
          "iam:GetInstanceProfile", "iam:CreateInstanceProfile",
          "iam:TagInstanceProfile", "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile", "iam:DeleteInstanceProfile"
        ]
        Resource = "*"
      },
      {
        Sid      = "EKS"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = aws_eks_cluster.this.arn
      }
    ]
  })
}

# ----- Helm install -----
resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  namespace  = "kube-system"
  version    = local.karpenter_version

  set {
    name  = "settings.clusterName"
    value = aws_eks_cluster.this.name
  }
  set {
    name  = "settings.clusterEndpoint"
    value = aws_eks_cluster.this.endpoint
  }
  set {
    name  = "settings.interruptionQueue"
    value = ""
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.karpenter_controller.arn
  }
  set {
    name  = "replicas"
    value = "1"
  }
  set {
    name  = "controller.resources.requests.cpu"
    value = "200m"
  }
  set {
    name  = "controller.resources.requests.memory"
    value = "256Mi"
  }

  depends_on = [
    aws_eks_node_group.main,
    aws_iam_role_policy.karpenter_controller,
  ]
}

# ----- NodePool + EC2NodeClass (Windows 호환: bash/kubectl 대신 kubectl_manifest) -----
resource "kubectl_manifest" "karpenter_nodeclass" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = "default" }
    spec = {
      amiSelectorTerms = [{ alias = "al2023@latest" }]
      instanceProfile  = aws_iam_instance_profile.karpenter_node.name
      kubelet          = { maxPods = var.node_max_pods }
      subnetSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = aws_eks_cluster.this.name }
      }]
      securityGroupSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = aws_eks_cluster.this.name }
      }]
    }
  })

  depends_on = [
    helm_release.karpenter,
    aws_eks_access_entry.karpenter_node,
  ]
}

resource "kubectl_manifest" "karpenter_nodepool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "default" }
    spec = {
      template = {
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          requirements = [
            {
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              values   = local.karpenter_instance_types
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["on-demand"]
            }
          ]
          expireAfter = "720h"
        }
      }
      limits = { cpu = tostring(var.karpenter_cpu_limit) }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        # 30s 는 너무 공격적이었다. 실측: 부하가 잠깐 내려가면 파드가 올라가 있는 노드까지
        # 30초 만에 회수하고("Underutilized ... pod-count:2 ... delete"), 곧바로 HPA 가
        # 파드를 늘리면 새 노드 부팅(60~90s) 동안 "Insufficient cpu" 로 스케줄이 막혀
        # 요청이 실패했다(가용성·성능 동시 손실).
        # 2분: 5분은 저부하 구간에도 노드를 오래 붙잡아 평균 노드 수(=비용 ratio)를 키웠다
        # (측정 2.1배, 비용 7/12). 가용성 여유(99.5~100%)가 크므로 회수를 앞당겨 비용을
        # 회수한다. 30s만큼 공격적이지 않아 재프로비저닝 중 "Insufficient cpu" 위험은 억제.
        consolidateAfter = "2m"
        # 회수 사유별로 속도를 다르게 둔다.
        #  - Empty: 파드가 아예 없는 노드 → 지워도 중단이 없으므로 한꺼번에 회수(비용↓).
        #  - Underutilized/Drifted: 파드가 올라가 있는 노드 → 한 번에 1대만.
        #    (기본값 10% 는 노드가 늘면 여러 대를 동시에 빼서 재스케줄이 몰린다)
        # 이렇게 하면 부하가 끝난 뒤 빈 노드가 1대씩 5분 간격으로 빠지는 대신
        # 한 번에 정리되어 평균 노드 수(비용 ratio)가 줄어든다.
        budgets = [
          { nodes = "100%", reasons = ["Empty"] },
          # 1 -> 2: 부하가 빠질 때 파드 실린 노드를 회당 2대까지 회수해 평균 노드 수를 더
          # 빨리 줄인다(비용). 가용성 여유가 커서 재스케줄 몰림 리스크를 감수할 만하다.
          { nodes = "2", reasons = ["Underutilized", "Drifted"] },
        ]
      }
    }
  })

  depends_on = [kubectl_manifest.karpenter_nodeclass]
}
