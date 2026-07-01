# ═══════════════════════════════════════════════════════════════
# App Load Balancer  (과제 12.1)  — wsc-app-lb
#   - Internal (Private Subnet), 외부 직접 접근 불가 (채점 7-1-B 타임아웃)
#   - CloudFront(VPC Origin) 를 통해서만 접근
#   - 라우팅:
#       POST /v1/book  -> book Pod TG (booking 생성)
#       GET  /v1/book  -> Lambda TG  (조회)
#       그 외          -> 404 "Contents Not Found"
# 채점 7-1-A: scheme internal, private subnet
# ═══════════════════════════════════════════════════════════════

resource "aws_security_group" "app_lb" {
  name        = "wsc-app-lb-sg"
  description = "wsc-app-lb - CloudFront(VPC origin) only"
  vpc_id      = data.aws_vpc.this.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "wsc-app-lb-sg" }
  # NOTE: ingress 80 은 CloudFront VPC Origin ENI 의 SG 만 허용해야
  #       채점 7-1-B(직접 접근 타임아웃)를 통과한다.
  #       VPC Origin 생성 후 만들어지는 'CloudFront-VPCOrigins-Service-SG' 를
  #       source 로 거는 규칙을 아래 data 로 연결한다. (README 4번 항목 참고)
}

# CloudFront VPC Origin 이 사용하는 관리형 SG (VPC Origin 최초 생성 후 존재)
data "aws_security_group" "cf_vpc_origin" {
  filter {
    name   = "group-name"
    values = ["CloudFront-VPCOrigins-Service-SG"]
  }
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  depends_on = [aws_cloudfront_vpc_origin.app_lb]
}

resource "aws_security_group_rule" "app_lb_from_cf" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = data.aws_security_group.cf_vpc_origin.id
  security_group_id        = aws_security_group.app_lb.id
  description              = "CloudFront VPC origin only"
}

# ALB -> book Pod(8080) 허용. 터라폼 생성 ALB + TargetGroupBinding 조합에선 lb-controller 가
# 백엔드 SG 규칙을 자동으로 안 열어주므로, 클러스터 SG(파드 ENI)에 ALB SG 출처 8080 을 명시 허용한다.
# (없으면 TG 헬스체크가 Target.Timeout -> unhealthy -> 앱 504)
resource "aws_vpc_security_group_ingress_rule" "cluster_from_app_lb" {
  security_group_id            = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.app_lb.id
  description                  = "wsc-app-lb to book pods 8080"
}

resource "aws_lb" "app" {
  name               = "wsc-app-lb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.app_lb.id]
  subnets            = [data.aws_subnet.private_a.id, data.aws_subnet.private_c.id]
  tags               = { Name = "wsc-app-lb" }
}

# book Pod 용 TG (LB Controller TargetGroupBinding 으로 Pod IP 등록)
resource "aws_lb_target_group" "book" {
  name        = "wsc-book-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.this.id
  target_type = "ip"
  health_check {
    path     = "/health"
    protocol = "HTTP"
    matcher  = "200"
  }
  tags = { Name = "wsc-book-tg" }
}

# Lambda 용 TG
resource "aws_lb_target_group" "lambda" {
  name        = "wsc-lambda-tg"
  target_type = "lambda"
  tags        = { Name = "wsc-lambda-tg" }
}

resource "aws_lb_target_group_attachment" "lambda" {
  target_group_arn = aws_lb_target_group.lambda.arn
  target_id        = aws_lambda_function.get_table.arn
  depends_on       = [aws_lambda_permission.alb]
}

resource "aws_lb_listener" "app" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "Contents Not Found"
      status_code  = "404"
    }
  }
}

# POST /v1/book -> book Pod
resource "aws_lb_listener_rule" "book_post" {
  listener_arn = aws_lb_listener.app.arn
  priority     = 10
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.book.arn
  }
  condition {
    path_pattern { values = ["/v1/book"] }
  }
  condition {
    http_request_method { values = ["POST"] }
  }
}

# GET /v1/book -> Lambda
resource "aws_lb_listener_rule" "book_get" {
  listener_arn = aws_lb_listener.app.arn
  priority     = 20
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.lambda.arn
  }
  condition {
    path_pattern { values = ["/v1/book"] }
  }
  condition {
    http_request_method { values = ["GET"] }
  }
}

# ═══════════════════════════════════════════════════════════════
# AWS Load Balancer Controller (addon LB / wsc-addon-lb 및 book TGB 관리)
# ═══════════════════════════════════════════════════════════════
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

# NOTE: AWS Load Balancer Controller Helm 차트와 book TargetGroupBinding(kubectl)은
#       2단계(k8s/) 스테이지(k8s/main.tf)로 분리되었다.
#       여기(root)에는 IAM Policy/Role/Attachment + Pod Identity Association 만 남긴다.
#       (book TG(wsc-book-tg)는 위에서 생성되며, k8s 스테이지가 data 로 조회해 바인딩한다.)
