# ═══════════════════════════════════════════════════════════════
# Application Load Balancer (book)  (과제 10)
#   - Name: wskorea26-book-alb / Internet-facing / Listener HTTP 80
#   - Public Subnet (pub-c/-d)
#   - CloudFront 를 통해서만 접근(헤더 X-Origin-Verify=wskorea26-cf 검증).
#     헤더 없으면 default action 403.
#   - 라우팅:
#       POST /v1/book (CloudFront Function 이 /book -> /v1/book 재작성) -> book Pod TG
#       GET  /book*   -> Lambda TG (concert_name 조회)
# 채점 7-1: scheme internet-facing, 80/HTTP
# 채점 7-2: 룰 헤더값 wskorea26-cf, 헤더 없는 직접요청 403
# ═══════════════════════════════════════════════════════════════

# ALB SG: HTTP 80 inbound any open (선수 유의사항 6)
resource "aws_security_group" "book_alb" {
  name        = "wskorea26-book-alb-sg"
  description = "book ALB - HTTP 80 open"
  vpc_id      = aws_vpc.this.id
  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "wskorea26-book-alb-sg" }
}

resource "aws_lb" "book" {
  name               = "wskorea26-book-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.book_alb.id]
  subnets            = [aws_subnet.pub_c.id, aws_subnet.pub_d.id]
  tags               = { Name = "wskorea26-book-alb" }
}

# book Pod TG (LB Controller TargetGroupBinding 으로 Pod IP 등록)
resource "aws_lb_target_group" "book" {
  name        = "wskorea26-book-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip"
  health_check {
    path     = "/health"
    protocol = "HTTP"
    matcher  = "200"
  }
  tags = { Name = "wskorea26-book-tg" }
}

# Lambda TG
resource "aws_lb_target_group" "lambda" {
  name        = "wskorea26-lambda-tg"
  target_type = "lambda"
  tags        = { Name = "wskorea26-lambda-tg" }
}

resource "aws_lb_target_group_attachment" "lambda" {
  target_group_arn = aws_lb_target_group.lambda.arn
  target_id        = aws_lambda_function.book.arn
  depends_on       = [aws_lambda_permission.alb]
}

resource "aws_lb_listener" "book" {
  load_balancer_arn = aws_lb.book.arn
  port              = 80
  protocol          = "HTTP"

  # 헤더 검증 실패(=CloudFront 미경유) -> 403
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}

# POST /v1/book + CloudFront 헤더 -> book Pod
resource "aws_lb_listener_rule" "book_post" {
  listener_arn = aws_lb_listener.book.arn
  priority     = 10
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.book.arn
  }
  condition {
    path_pattern { values = ["/v1/book", "/book"] }
  }
  condition {
    http_request_method { values = ["POST"] }
  }
  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [var.cf_origin_verify]
    }
  }
}

# GET /book* + CloudFront 헤더 -> Lambda
resource "aws_lb_listener_rule" "book_get" {
  listener_arn = aws_lb_listener.book.arn
  priority     = 20
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.lambda.arn
  }
  condition {
    path_pattern { values = ["/book*"] }
  }
  condition {
    http_request_method { values = ["GET"] }
  }
  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [var.cf_origin_verify]
    }
  }
}

# ═══════════════════════════════════════════════════════════════
# AWS Load Balancer Controller (book TGB + Grafana Service LB 관리)
# ═══════════════════════════════════════════════════════════════
resource "aws_iam_policy" "lb_controller" {
  name   = "wskorea26-AWSLoadBalancerControllerIAMPolicy"
  policy = file("${path.module}/files/lb-controller-policy.json")
}

resource "aws_iam_role" "lb_controller" {
  name = "wskorea26-lb-controller-role"
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

resource "helm_release" "lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = aws_eks_cluster.this.name
  }
  set {
    name  = "region"
    value = local.region
  }
  set {
    name  = "vpcId"
    value = aws_vpc.this.id
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  # addon 노드그룹에 스케줄
  set {
    name  = "nodeSelector.node-type"
    value = "addon"
  }

  depends_on = [
    aws_eks_node_group.addon,
    aws_eks_pod_identity_association.lb_controller,
    aws_eks_addon.coredns,
  ]
}

# book Service -> book TG 바인딩 (TargetGroupBinding CRD)
resource "null_resource" "book_tgb" {
  triggers = {
    tg = aws_lb_target_group.book.arn
  }
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      REGION  = local.region
      CLUSTER = aws_eks_cluster.this.name
      TG_ARN  = aws_lb_target_group.book.arn
      NS      = local.namespace
    }
    command = <<-EOT
      set -euo pipefail
      aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null
      f=$(mktemp)
      {
        echo "apiVersion: elbv2.k8s.aws/v1beta1"
        echo "kind: TargetGroupBinding"
        echo "metadata:"
        echo "  name: wskorea26-book-tgb"
        echo "  namespace: $NS"
        echo "spec:"
        echo "  serviceRef:"
        echo "    name: wskorea26-book-svc"
        echo "    port: 80"
        echo "  targetType: ip"
        echo "  targetGroupARN: $TG_ARN"
      } > "$f"
      for i in $(seq 1 30); do
        if kubectl apply -f "$f"; then exit 0; fi
        sleep 10
      done
      echo "TargetGroupBinding apply failed (CRD not ready?)" >&2
      exit 1
    EOT
  }
  depends_on = [helm_release.lb_controller, aws_lb_target_group.book, kubernetes_service_v1.book]
}
