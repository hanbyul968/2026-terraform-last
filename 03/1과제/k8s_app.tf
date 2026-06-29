# ═══════════════════════════════════════════════════════════════
# Book App — AWS 레이어  (과제 8)
#   kubernetes_*/helm_release(book Deployment/Service/Ingress 등 + LB Controller helm)
#   는 ./k8s 스테이지로 분리했다. 이 파일에는 AWS 리소스만 남긴다:
#     - book Pod Identity 연결 (SA 이름 문자열 기반)
#     - AWS Load Balancer Controller 의 IAM/Policy/Pod Identity
# ═══════════════════════════════════════════════════════════════

# ── book SA(./k8s 에서 생성) 에 대한 Pod Identity (DynamoDB PutItem) ──
resource "aws_eks_pod_identity_association" "book" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = local.app_namespace
  service_account = local.sa_name
  role_arn        = aws_iam_role.book_pod.arn
  depends_on      = [aws_eks_addon.pod_identity]
}

# ═══════════════════════════════════════════════════════════════
# AWS Load Balancer Controller — IAM / Pod Identity
#   (helm_release.lb_controller 는 ./k8s 스테이지로 이동)
# ═══════════════════════════════════════════════════════════════
resource "aws_iam_policy" "lb_controller" {
  name   = "wsc2026-AWSLoadBalancerControllerIAMPolicy"
  policy = file("${path.module}/files/lb-controller-policy.json")
}

resource "aws_iam_role" "lb_controller" {
  name = "wsc2026-lb-controller-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

resource "aws_eks_pod_identity_association" "lb_controller" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lb_controller.arn
  depends_on      = [aws_eks_addon.pod_identity]
}
