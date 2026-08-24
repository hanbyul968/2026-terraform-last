# ALB created natively in Terraform (no AWS Load Balancer Controller).
# Routing: ip-type target groups; pods are registered by the AWS Load Balancer
# Controller via TargetGroupBinding (covers managed-node-group AND Karpenter nodes).
# This decouples CloudFront from the EKS provisioning chain — ALB exists ~2min in,
# so CloudFront distribution deploys in parallel with the cluster.

// 앱 목록/포트/TG prefix 는 모두 apps.tf 의 local.apps 에서 온다.
// (local.node_ports 는 apps.tf 에서 파생되어 하위 호환용으로 유지)

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "ALB ingress"
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
}

resource "aws_lb" "this" {
  name               = "${local.name}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  idle_timeout       = 60
}

resource "aws_lb_target_group" "app" {
  for_each = local.apps

  # name_prefix (not name): with create_before_destroy, a future replacement
  # must coexist briefly with the old TG — a fixed name would collide.
  # prefix 는 앱 이름 앞 5자에서 자동 생성 (apps.tf) → 앱이 바뀌어도 충돌 없음.
  name_prefix = each.value.tg_prefix
  port        = each.value.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip"

  deregistration_delay = 20

  # 처리 중 요청이 가장 적은 타깃으로 전달. Target Group 속성만 바뀌므로 Pod 롤아웃 없음.
  load_balancing_algorithm_type = "least_outstanding_requests"

  lifecycle {
    create_before_destroy = true
  }

  health_check {
    path                = each.value.healthcheck_path
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
    timeout             = 5
    matcher             = "200"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # Unknown paths → 404 (per problem spec)
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"err\":\"not found\"}"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "app" {
  for_each = local.apps

  listener_arn = aws_lb_listener.http.arn
  priority     = index(sort(keys(local.apps)), each.key) + 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app[each.key].arn
  }

  # path AND origin-verify header (set by CloudFront) — both must match to forward.
  # 경로는 앱별 path (apps.tf) — api_prefix 변경이나 앱별 커스텀 경로 모두 대응.
  condition {
    path_pattern {
      values = [each.value.path, "${each.value.path}/*"]
    }
  }
  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.origin_verify.result]
    }
  }
}

# Requests to a valid API path WITHOUT the CloudFront origin-verify header did not
# come through CloudFront (direct-to-ALB / abnormal) → 403. (Unknown paths → 404
# via the listener default action.) This replaces the old ALB-scoped WAF rule.
resource "aws_lb_listener_rule" "deny_direct" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 50

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"err\":\"forbidden\"}"
      status_code  = "403"
    }
  }

  condition {
    # 정확히 유효 엔드포인트만 (와일드카드 X) — /v1/users 같은 미정의 경로는 default 404 로.
    # 단일 소스 local.api_paths (locals.tf) — WAF scope-down 과 항상 일치.
    path_pattern {
      values = local.api_paths
    }
  }
}

resource "aws_lb_listener_rule" "healthcheck" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 5

  action {
    type = "forward"
    # 아무 앱이나 하나로 보내면 된다(헬스체크는 DB 를 보지 않는다).
    # 앱 이름을 하드코딩하지 않고 정렬된 첫 앱을 쓴다 → 앱이 바뀌어도 동작.
    target_group_arn = aws_lb_target_group.app[local.first_app].arn
  }

  condition {
    path_pattern {
      values = [var.healthcheck_path]
    }
  }
}

# Nodes (managed node group AND Karpenter) use the EKS cluster primary SG.
# Allow ALB to reach pod IPs on 8080 for ip-type targets + health checks.
resource "aws_security_group_rule" "alb_to_pods" {
  type                     = "ingress"
  from_port                = var.container_port
  to_port                  = var.container_port
  protocol                 = "tcp"
  security_group_id        = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  source_security_group_id = aws_security_group.alb.id
  description              = "ALB to pods"
}

# Karpenter discovers this SG by tag and attaches it to the nodes it launches.
resource "aws_ec2_tag" "cluster_sg_discovery" {
  resource_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = aws_eks_cluster.this.name
}
