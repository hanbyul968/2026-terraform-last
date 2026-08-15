# ---------------------------------------------------------------------------
# 모니터링/로깅 (문제지 필수 요구)
#   - 로그그룹: color 앱 access log (CloudWatch Agent 가 전송)
#   - 알람: 타깃 5xx / 비정상 호스트 / 응답시간 SLO / CPU
#   - 대시보드: 트래픽/응답시간/HTTP코드/호스트/CPU 한 화면
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  tags              = { Name = "${local.name}-log" }
}

# 타깃(앱) 5xx 급증
resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "${local.name}-target-5xx"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
  }
  alarm_description = "color 타깃 5xx 응답 급증"
  tags              = { Name = "${local.name}-target-5xx" }
}

# 비정상(헬스체크 실패) 호스트 발생 -> 가용성 위협
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${local.name}-unhealthy-hosts"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  dimensions = {
    TargetGroup  = aws_lb_target_group.color.arn_suffix
    LoadBalancer = aws_lb.this.arn_suffix
  }
  alarm_description = "헬스체크 실패 인스턴스 발생"
  tags              = { Name = "${local.name}-unhealthy-hosts" }
}

# 응답시간 SLO(1초) 위반 (타깃 응답시간 p90 기준)
resource "aws_cloudwatch_metric_alarm" "latency_slo" {
  alarm_name          = "${local.name}-latency-slo"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p90"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
  }
  alarm_description = "타깃 응답시간 p90 > 1s (SLO 위반)"
  tags              = { Name = "${local.name}-latency-slo" }
}

# ASG 평균 CPU 과부하 (스케일 정책과 별개로 경보)
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${local.name}-cpu-high"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  treat_missing_data  = "notBreaching"
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.color.name
  }
  alarm_description = "ASG 평균 CPU 80% 초과"
  tags              = { Name = "${local.name}-cpu-high" }
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "${local.name}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "ALB Requests / Target Response Time"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.this.arn_suffix, { stat = "Sum" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.this.arn_suffix, { stat = "p90", yAxis = "right" }]
          ]
          period = 60
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title   = "HTTP Codes (Target)"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          stacked = true
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_2XX_Count", "LoadBalancer", aws_lb.this.arn_suffix, { stat = "Sum" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", aws_lb.this.arn_suffix, { stat = "Sum" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.this.arn_suffix, { stat = "Sum" }]
          ]
          period = 60
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "Healthy / Unhealthy Hosts"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", aws_lb_target_group.color.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { stat = "Average" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", aws_lb_target_group.color.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { stat = "Average" }]
          ]
          period = 60
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "ASG CPU / Memory"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", aws_autoscaling_group.color.name, { stat = "Average" }],
            [local.metrics_namespace, "mem_used_percent", "AutoScalingGroupName", aws_autoscaling_group.color.name, { stat = "Average" }]
          ]
          period = 60
        }
      }
    ]
  })
}
