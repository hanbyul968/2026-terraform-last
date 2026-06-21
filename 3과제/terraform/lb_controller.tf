# AWS Load Balancer Controller — used ONLY for TargetGroupBinding (pod IP
# registration into the TF-managed target groups). The ALB itself is native
# Terraform, so this is off the CloudFront critical path.

data "aws_iam_policy_document" "alb_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "${local.name}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.alb_assume.json
}

resource "aws_iam_policy" "alb_controller" {
  name   = "${local.name}-alb-controller"
  policy = file("${path.module}/policies/alb-controller.json")
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

resource "kubernetes_service_account" "alb_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller.arn
    }
  }
}

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "3.4.0"

  set {
    name  = "clusterName"
    value = aws_eks_cluster.this.name
  }
  set {
    name  = "serviceAccount.create"
    value = "false"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "region"
    value = var.region
  }
  set {
    name  = "vpcId"
    value = aws_vpc.this.id
  }
  # 우리는 LoadBalancer 타입 Service를 쓰지 않고 네이티브 ALB + TargetGroupBinding만 사용한다.
  # Service 변형 웹훅(mservice)은 클러스터 전체 Service 생성을 가로채는데, 컨트롤러가
  # Ready 되기 전엔 fail-closed로 metrics-server/karpenter 등 모든 Service 생성을 막는다 → 비활성화.
  set {
    name  = "enableServiceMutatorWebhook"
    value = "false"
  }

  depends_on = [
    kubernetes_service_account.alb_controller,
    aws_eks_node_group.main,
  ]
}

# Bind each k8s service to its TF-managed target group (pod IP targets).
# Windows 호환: bash/kubectl/임시파일 대신 네이티브 kubectl_manifest 사용.
resource "kubectl_manifest" "tgb" {
  for_each = aws_lb_target_group.app

  yaml_body = yamlencode({
    apiVersion = "elbv2.k8s.aws/v1beta1"
    kind       = "TargetGroupBinding"
    metadata = {
      name      = each.key
      namespace = "app"
    }
    spec = {
      serviceRef = {
        name = each.key
        port = 80
      }
      targetGroupARN = each.value.arn
      targetType     = "ip"
    }
  })

  depends_on = [
    helm_release.alb_controller,
    kubernetes_service.user,
    kubernetes_service.product,
    kubernetes_service.stress,
  ]
}
