# ═══════════════════════════════════════════════════════════════
# ALB  (과제 12)  — wsc2026-app-alb
#   - AWS Load Balancer Controller 가 Ingress(wsc2026-book-ingress)로 생성
#   - scheme: internet-facing
#   - CloudFront 를 통해서만 접근 (SG = CloudFront origin-facing prefix list 만 허용)
#   - 잘못된 경로는 403 (ingress default 503 대신 명시적 403 action)
#
# 여기서는 ALB 에 붙일 SG(wsc2026-app-alb-sg) 와,
# 생성된 ALB 를 CloudFront origin 으로 쓰기 위한 조회(data)를 정의한다.
# (ALB 자체는 k8s_app.tf 의 ingress 가 만든다)
#
# 채점 8-1: scheme internet-facing / SG wsc2026-app-alb-sg / 직접접근 BLOCKED
# ═══════════════════════════════════════════════════════════════

# CloudFront origin-facing 관리형 prefix list
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name        = local.alb_sg_name
  description = "wsc2026 ALB - CloudFront only"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "CloudFront origin-facing only (HTTP)"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = local.alb_sg_name }
}

# ── ingress 가 만든 ALB 를 CloudFront origin 으로 쓰기 위해 조회 ──
# LBC 가 ALB 를 프로비저닝하는 데 시간이 걸리므로 active 까지 대기.
resource "null_resource" "wait_alb" {
  triggers = { ingress = local.ingress_name }
  provisioner "local-exec" {
    interpreter = ["powershell", "-NoProfile", "-Command"]
    environment = { REGION = local.region, ALB = local.alb_name }
    command     = <<-EOT
      $ErrorActionPreference = 'Stop'
      for ($i=0; $i -lt 60; $i++) {
        $arn = (aws elbv2 describe-load-balancers --region $env:REGION --names $env:ALB --query "LoadBalancers[0].State.Code" --output text 2>$null)
        if ($arn -eq 'active') { exit 0 }
        Start-Sleep -Seconds 15
      }
      throw "ALB $env:ALB not active in time"
    EOT
  }
  depends_on = [kubernetes_ingress_v1.book]
}

data "aws_lb" "app" {
  name       = local.alb_name
  depends_on = [null_resource.wait_alb]
}
