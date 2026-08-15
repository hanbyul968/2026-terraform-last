# ---------------------------------------------------------------------------
# 컴퓨팅: Launch Template + Auto Scaling Group (t3.micro, 2AZ)
#  - AMI 는 SSM 파라미터에서 최신 AL2023 조회
#  - user-data 로 color 앱 빌드/구동 + CloudWatch Agent 구성
#  - ELB 헬스체크로 /healthcheck 실패 인스턴스 자동 교체
#  - CPU 타깃 트래킹으로 트래픽에 맞춰 스케일(저비용<->가용성 균형)
# ---------------------------------------------------------------------------

resource "aws_launch_template" "color" {
  name_prefix   = "${local.name}-lt-"
  image_id      = data.aws_ssm_parameter.al2023_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2.arn
  }

  vpc_security_group_ids = [aws_security_group.ec2.id]

  user_data = base64encode(templatefile("${path.module}/userdata.sh.tftpl", {
    artifact_bucket    = aws_s3_bucket.artifacts.id
    artifact_key       = aws_s3_object.color.key
    artifact_hash      = aws_s3_object.color.source_hash
    region             = var.region
    container_port     = var.container_port
    log_group          = local.log_group_name
    log_retention_days = var.log_retention_days
    metrics_namespace  = local.metrics_namespace
  }))

  # IMDSv2 강제(보안 모범사례)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  monitoring {
    enabled = false # 기본(5분) 모니터링으로 비용 절감. 필요 시 true.
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${local.name}-color" }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${local.name}-color" }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "color" {
  name                      = "${local.name}-asg"
  vpc_zone_identifier       = aws_subnet.public[*].id
  min_size                  = var.asg_min_size
  desired_capacity          = var.asg_desired_size
  max_size                  = var.asg_max_size
  health_check_type         = "ELB"
  health_check_grace_period = 120
  target_group_arns         = [aws_lb_target_group.color.arn]

  launch_template {
    id      = aws_launch_template.color.id
    version = "$Latest"
  }

  # 무중단 롤링 교체(런치템플릿 변경 시 앱 재빌드 반영)
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name}-color"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# CPU 평균을 목표치로 유지하는 타깃 트래킹 스케일링
resource "aws_autoscaling_policy" "cpu_target" {
  name                   = "${local.name}-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.color.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.cpu_target
  }
}
