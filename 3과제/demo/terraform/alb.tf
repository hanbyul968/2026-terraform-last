# ---------------------------------------------------------------------------
# ALB : CloudFront 원본. 인터넷 대면이지만 SG 로 CloudFront edge 만 허용.
#       Listener :80 -> Target Group :8080, 헬스체크 /healthcheck.
# ---------------------------------------------------------------------------

resource "aws_lb" "this" {
  name               = "${local.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  # 이름 32자 제한 대비: project(기본 15) + suffix(5) + "-alb" 여유
  tags = { Name = "${local.name}-alb" }
}

resource "aws_lb_target_group" "color" {
  name        = "${local.name}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = var.healthcheck_path
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30

  tags = { Name = "${local.name}-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.color.arn
  }
}
