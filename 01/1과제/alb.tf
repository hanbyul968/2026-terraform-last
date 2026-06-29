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
########################
