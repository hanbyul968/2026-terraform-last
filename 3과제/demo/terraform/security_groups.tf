# ---------------------------------------------------------------------------
# 보안그룹
#   ALB : 인바운드 80 을 CloudFront(origin-facing prefix list)에서만 허용
#   EC2 : 인바운드 앱 포트를 ALB SG 에서만 허용. SSH 없음(접속은 SSM 사용).
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "ALB - allow HTTP only from CloudFront"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "HTTP from CloudFront edge only"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-alb-sg" }
}

resource "aws_security_group" "ec2" {
  name        = "${local.name}-ec2-sg"
  description = "EC2 - allow app port only from ALB"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "App port from ALB"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "All outbound (dnf, go modules, CloudWatch, SSM)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-ec2-sg" }
}
