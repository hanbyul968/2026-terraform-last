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
      kubelet          = { maxPods = local.node_max_pods_effective }
      subnetSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = aws_eks_cluster.this.name }
      }]
      securityGroupSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = aws_eks_cluster.this.name }
      }]
    }
  })

  # 서브넷/라우팅이 완성된 뒤에 NodeClass 를 만든다.
  #
  # 이유(실측): 초기 apply 중 Karpenter 로그에 아래 에러가 반복됐다.
  #   "failed listing instance types ... nodepool=default/isolated, error: no subnets found"
  # 서브넷 태그(karpenter.sh/discovery, vpc.tf 의 aws_subnet.public)는 정상이었고
  # 잠시 뒤 스스로 해소됐다(=일시적 레이스). 그래도 이 에러가 지속되면 스케일아웃이
  # 아예 막히므로(부하 중이면 치명적), 순서를 명시해 발생 창을 없앤다.
  #
  # ⚠ 태그를 aws_ec2_tag 로 따로 또 붙이지 않는다. aws_subnet.public 이 tags 를
  #   인라인으로 소유하므로 이중 관리가 되어 매 apply 마다 서로 덮어쓰는 drift 가 난다.
  depends_on = [
    helm_release.karpenter,
    aws_eks_access_entry.karpenter_node,
    aws_subnet.public,
    aws_route_table_association.public,
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
      limits = { cpu = tostring(local.karpenter_cpu_limit_effective) }
      disruption = {
        # 성능 우선: WhenEmpty 만 회수한다.
        # WhenEmptyOrUnderutilized 는 파드가 올라가 있는 노드도 "덜 찼다"고 판단해 비우는데,
        # 그 과정에서 파드가 evict -> 재스케줄 -> 새 노드 부팅(60~90s) 되는 동안 지연이 튄다.
        # 실측: user p50 이 126ms -> 369ms 로 진동했고, Karpenter 로그에 회수/재프로비저닝이
        # 반복됐다. WhenEmpty 는 '파드가 하나도 없는 노드'만 지우므로 부하 중 중단이 없다.
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = "1m"
        budgets = [
          # 빈 노드는 지워도 중단이 없으므로 한꺼번에 회수한다.
          { nodes = "100%", reasons = ["Empty"] },
          # 파드가 실린 노드는 건드리지 않는다(WhenEmpty 라 사실상 발생 안 함).
          { nodes = "0", reasons = ["Underutilized"] },
          { nodes = "1", reasons = ["Drifted"] },
        ]
      }
    }
  })

  depends_on = [kubectl_manifest.karpenter_nodeclass]
}


# ---------------------------------------------------------------------------
# 격리 노드풀 — isolate=true 인 앱 전용 (apps.tf 의 local.isolated_apps)
#
# 왜 필요한가 (실측 근거):
#   전체 트래픽의 4% 밖에 안 되는 CPU 폭식 앱이 클러스터 CPU 를 거의 다 소비해,
#   트래픽 75% 를 받는 지연 민감 앱의 p50 이 27ms -> 330ms 로 악화됐다.
#   지연 민감 앱은 CPU 를 거의 안 쓰는데도(request 의 9%) 응답이 느려진 이유는
#   CPU 를 기다리는 런큐 대기였다. 같은 노드에 두면 cgroup share 비율로만 나뉘어
#   폭식 앱이 항상 이긴다.
#
# 해결: taint 를 걸어 폭식 앱만 이 노드풀에 격리한다. 지연 민감 앱은 toleration 이
# 없으므로 커널/스케줄러 수준에서 절대 같은 노드에 앉지 않는다.
#
# 노드 수는 karpenter_isolated_max_nodes 로 따로 제한한다 — 폭식 앱이 비용을
# 무한히 밀어 올리지 못하게 하는 상한이다. 비용(12점)과 폭식 앱 성능(4점) 사이의
# 트레이드오프를 이 값 하나로 조절한다.
# ---------------------------------------------------------------------------
resource "kubectl_manifest" "karpenter_nodepool_isolated" {
  count = local.need_isolated_pool ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "isolated" }
    spec = {
      template = {
        metadata = {
          labels = { (local.isolated_label_key) = local.isolated_label_val }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          # toleration 이 있는 파드만 여기 올 수 있다.
          taints = [{
            key    = local.isolated_taint_key
            value  = "true"
            effect = "NoSchedule"
          }]
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
      limits = { cpu = tostring(local.karpenter_isolated_cpu_limit) }
      disruption = {
        # 격리 풀은 general 풀과 정책이 다르다.
        #
        # general 풀(user/product, SLO 0.2s)은 WhenEmpty 다 — 부하 중 파드를 옮기면
        # 지연이 튀므로 파드가 실린 노드는 건드리지 않는다.
        #
        # 격리 풀(stress)은 WhenEmptyOrUnderutilized 여야 한다. 이유(실측):
        #   stress min_replicas=2 + hostname topology spread 로 파드가 노드마다 1개씩
        #   흩어져서, WhenEmpty 기준으로는 어느 노드도 '비어 있지' 않아 2대가 영구히
        #   남았다(각 노드에 stress 파드 1개). 한 노드에 2개를 모으면 1대로 충분하다.
        #   stress 는 SLO 가 1s 로 느슨하고 재스케줄 지연을 감당할 수 있으므로,
        #   여기서는 회수를 허용해 유휴 노드를 없앤다.
        #   (hostname maxSkew=2 라 노드당 2개까지 허용되어 통합 계획이 성립한다)
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "2m"
        budgets = [
          # 빈 노드는 즉시, 파드가 실린 노드는 한 번에 1대만(재스케줄 몰림 방지).
          { nodes = "100%", reasons = ["Empty"] },
          { nodes = "1", reasons = ["Underutilized", "Drifted"] },
        ]
      }
    }
  })

  depends_on = [kubectl_manifest.karpenter_nodeclass]
}
