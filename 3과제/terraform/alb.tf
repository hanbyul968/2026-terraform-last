# ALB created natively in Terraform (no AWS Load Balancer Controller).
# Routing: ip-type target groups; pods are registered by the AWS Load Balancer
# Controller via TargetGroupBinding (covers managed-node-group AND Karpenter nodes).
# This decouples CloudFront from the EKS provisioning chain — ALB exists ~2min in,
# so CloudFront distribution deploys in parallel with the cluster.

locals {
  tg_prefix = {
    user    = "u-"
    product = "p-"
    stress  = "s-"
  }
  node_ports = {
    user    = 30080
    product = 30081
    stress  = 30082
  }
}

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
  for_each = local.node_ports

  # name_prefix (not name): with create_before_destroy, a future replacement
  # must coexist briefly with the old TG — a fixed name would collide.
  name_prefix = local.tg_prefix[each.key]
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip"

  deregistration_delay = 20

  lifecycle {
    create_before_destroy = true
  }

  health_check {
    path                = "/healthcheck"
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
  for_each = aws_lb_target_group.app

  listener_arn = aws_lb_listener.http.arn
  priority     = index(keys(local.node_ports), each.key) + 10

  action {
    type             = "forward"
    target_group_arn = each.value.arn
  }

  condition {
    path_pattern {
      values = ["/v1/${each.key}", "/v1/${each.key}/*"]
    }
  }
}

resource "aws_lb_listener_rule" "healthcheck" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 5

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app["user"].arn
  }

  condition {
    path_pattern {
      values = ["/healthcheck"]
    }
  }
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.this.arn
  web_acl_arn  = aws_wafv2_web_acl.regional.arn
}

# Nodes (managed node group AND Karpenter) use the EKS cluster primary SG.
# Allow ALB to reach pod IPs on 8080 for ip-type targets + health checks.
resource "aws_security_group_rule" "alb_to_pods" {
  type                     = "ingress"
  from_port                = 8080
  to_port                  = 8080
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
