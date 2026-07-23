# Security Group
resource "aws_security_group" "alb" {
  name        = "${var.alb_name}-sg"
  description = "Security group for ALB"
  vpc_id      = var.vpc_id

  # 인바운드는 CloudFront 전용 소스만 허용한다.
  # 생성 전에는 AWS-managed origin-facing prefix list를, 생성 후에는
  # CloudFront-VPCOrigins-Service-SG를 허용하며 0.0.0.0/0은 사용하지 않는다.
  # 과제지 10-1: CloudFront를 거치지 않는 모든(내부망 포함) 요청은 거절한다.

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.alb_name}-sg"
  }
}

# CloudFront VPC Origin prerequisite:
# The origin-facing AWS-managed prefix list must be allowed before the VPC
# origin is created. The VPC-origin service SG is added later by the
# CloudFront module for tighter source-SG restriction.
data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group_rule" "cloudfront_origin_facing" {
  type              = "ingress"
  security_group_id = aws_security_group.alb.id
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  prefix_list_ids   = [data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id]
  description       = "Allow CloudFront origin-facing traffic for VPC Origin deployment"
}

# ALB (Internal)
resource "aws_lb" "this" {
  name               = var.alb_name
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.private_subnet_ids

  # Ensure the CloudFront prerequisite rule exists before the ALB ARN can be
  # consumed by aws_cloudfront_vpc_origin in the caller.
  depends_on = [aws_security_group_rule.cloudfront_origin_facing]

  tags = {
    Name = var.alb_name
  }
}

# Target Group for Book App (IP type for EKS pods)
resource "aws_lb_target_group" "app" {
  name        = var.tg_name
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = {
    Name = var.tg_name
  }
}

# Lambda Target Group
resource "aws_lb_target_group" "lambda" {
  name        = "${var.alb_name}-lambda-tg"
  target_type = "lambda"

  tags = {
    Name = "${var.alb_name}-lambda-tg"
  }
}

resource "aws_lambda_permission" "alb" {
  statement_id  = "AllowALBInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_arn
  principal     = "elasticloadbalancing.amazonaws.com"
}

resource "aws_lb_target_group_attachment" "lambda" {
  target_group_arn = aws_lb_target_group.lambda.arn
  target_id        = var.lambda_arn
  depends_on       = [aws_lambda_permission.alb]
}

# Listener with rules
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# GET /v1/book -> Lambda (except /health)
resource "aws_lb_listener_rule" "lambda_get" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.lambda.arn
  }

  condition {
    http_request_method {
      values = ["GET"]
    }
  }

  condition {
    path_pattern {
      values = ["/v1/book"]
    }
  }
}

# GET /health -> App
resource "aws_lb_listener_rule" "health" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 5

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  condition {
    path_pattern {
      values = ["/health"]
    }
  }
}
