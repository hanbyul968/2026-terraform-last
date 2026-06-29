############################
# ALB security group
############################
resource "aws_security_group" "alb" {
  name        = "wsc-alb-sg"
  description = "wsc-alb security group"
  vpc_id      = aws_vpc.this.id

  ingress {
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
  tags = { Name = "wsc-alb-sg" }
}

# ALB -> 노드(파드) 8080 허용
resource "aws_security_group_rule" "alb_to_nodes" {
  type                     = "ingress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

############################
# ALB (internet-facing, public subnets)
############################
resource "aws_lb" "wsc" {
  name               = "wsc-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.pub_a.id, aws_subnet.pub_b.id]
  tags               = { Name = "wsc-alb" }
}

resource "aws_lb_target_group" "book" {
  name        = "wsc-book-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip"

  health_check {
    path     = "/health"
    protocol = "HTTP"
    matcher  = "200"
  }
  tags = { Name = "wsc-book-tg" }
}

# 정의되지 않은 경로 -> 404 (default fixed-response)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.wsc.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"message\":\"not found\"}"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "health" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.book.arn
  }
  condition {
    path_pattern { values = ["/health"] }
  }
}

resource "aws_lb_listener_rule" "book" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 20
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.book.arn
  }
  condition {
    path_pattern { values = ["/v1/*"] }
  }
}

############################
# AWS Load Balancer Controller (manages TargetGroupBinding)
############################
resource "aws_iam_policy" "lb_controller" {
  name   = "wsc-AWSLoadBalancerControllerIAMPolicy"
  policy = file("${path.module}/files/lb-controller-policy.json")
}

resource "aws_iam_role" "lb_controller" {
  name = "wsc-lb-controller-role"
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
  set {
    name  = "nodeSelector.node"
    value = "addon"
  }

  depends_on = [
    aws_eks_node_group.addon,
    aws_eks_pod_identity_association.lb_controller,
    aws_eks_addon.coredns,
  ]
}

############################
# TargetGroupBinding (book svc -> book-tg) : kubectl apply (CRD plan 이슈 회피)
############################
resource "null_resource" "target_group_binding" {
  triggers = {
    tg  = aws_lb_target_group.book.arn
    svc = kubernetes_service_v1.book.metadata[0].name
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      REGION  = local.region
      CLUSTER = aws_eks_cluster.this.name
      TG_ARN  = aws_lb_target_group.book.arn
    }
    command = <<-EOT
      set -euo pipefail
      aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null
      f=$(mktemp)
      {
        echo "apiVersion: elbv2.k8s.aws/v1beta1"
        echo "kind: TargetGroupBinding"
        echo "metadata:"
        echo "  name: book-tgb"
        echo "  namespace: book"
        echo "spec:"
        echo "  serviceRef:"
        echo "    name: book"
        echo "    port: 8080"
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

  depends_on = [
    helm_release.lb_controller,
    kubernetes_service_v1.book,
    aws_lb_target_group.book,
  ]
}
