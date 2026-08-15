# ---------------------------------------------------------------------------
# 출력값. 채점 플랫폼에는 endpoint(프로토콜+주소, 경로 없음)를 입력한다.
# ---------------------------------------------------------------------------

output "endpoint" {
  description = "채점 플랫폼에 입력할 단일 https 엔드포인트 (경로 없이 이 값 그대로)"
  value       = "https://${aws_cloudfront_distribution.this.domain_name}"
}

output "smoke_test" {
  description = "배포 확인용 curl 명령"
  value = {
    color       = "curl -s https://${aws_cloudfront_distribution.this.domain_name}${var.color_path}"
    healthcheck = "curl -s -o /dev/null -w '%%{http_code}\\n' https://${aws_cloudfront_distribution.this.domain_name}${var.healthcheck_path}"
  }
}

output "cloudfront_domain" {
  description = "CloudFront 배포 도메인"
  value       = aws_cloudfront_distribution.this.domain_name
}

output "alb_dns_name" {
  description = "ALB DNS (내부 확인용, 사용자에게 노출 금지)"
  value       = aws_lb.this.dns_name
}

output "asg_name" {
  description = "Auto Scaling Group 이름"
  value       = aws_autoscaling_group.color.name
}

output "log_group_name" {
  description = "color 앱 로그그룹"
  value       = aws_cloudwatch_log_group.app.name
}

output "dashboard_name" {
  description = "CloudWatch 대시보드 이름"
  value       = aws_cloudwatch_dashboard.this.dashboard_name
}

output "region" {
  description = "배포 리전"
  value       = data.aws_region.current.name
}
