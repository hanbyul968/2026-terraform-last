# =============================================================================
# 8. Application Load Balancer
#  - 이름: <id>-book-alb / Scheme: internet-facing
#  - 서브넷: Public Subnet 2개
#  - Listener: HTTP:80
#  - Target Group: HTTP:8080, Target Type: ip, Health Check: /health (200)
# =============================================================================

resource "aws_lb" "book" {
  name               = "${local.prefix}-book-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = {
    Name = "${local.prefix}-book-alb"
  }
}

resource "aws_lb_target_group" "book" {
  name        = "${local.prefix}-book-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${local.prefix}-book-tg"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.book.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.book.arn
  }
}
