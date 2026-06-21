# =============================================================================
# 보안 그룹
#  - <id>-alb-sg : 인바운드 HTTP 80 from 0.0.0.0/0
#  - <id>-ecs-sg : 인바운드 TCP 8080 from alb-sg (SG ID), 아웃바운드 All
# =============================================================================

resource "aws_security_group" "alb" {
  name        = "${local.prefix}-alb-sg"
  description = "ALB SG - allow HTTP 80 from anywhere (incl. CloudFront)"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.prefix}-alb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from anywhere"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "ecs" {
  name        = "${local.prefix}-ecs-sg"
  description = "ECS SG - allow 8080 only from ALB SG"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.prefix}-ecs-sg"
  }
}

# 인바운드 TCP 8080 소스 = ALB SG (CIDR가 아닌 SG ID로 제한)
resource "aws_vpc_security_group_ingress_rule" "ecs_from_alb" {
  security_group_id            = aws_security_group.ecs.id
  description                  = "App port from ALB SG only"
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  referenced_security_group_id = aws_security_group.alb.id
}

# 아웃바운드 All (ECR, DynamoDB, CloudWatch 등)
resource "aws_vpc_security_group_egress_rule" "ecs_all" {
  security_group_id = aws_security_group.ecs.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
