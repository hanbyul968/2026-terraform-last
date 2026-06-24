terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

variable "alarm_email" {
  description = "SNS 이메일 알림 수신 주소 (채점항목 3-8)"
  type        = string
  default     = ""
}

locals {
  # 배포파일 app.py (Cloud event handling)
  app_py_b64 = filebase64("${path.module}/../../files/event-app.py")
}

# ─────────────────────────────────────────────
# Default VPC (없으면 자동 생성, 있으면 채택)
# ─────────────────────────────────────────────
resource "aws_default_vpc" "default" {}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_default_subnet" "az" {
  count             = 2
  availability_zone = data.aws_availability_zones.available.names[count.index]
  depends_on        = [aws_default_vpc.default]
}

# ─────────────────────────────────────────────
# Security Group: EC2
# ─────────────────────────────────────────────
resource "aws_security_group" "event" {
  name   = "gj2026-event-sg"
  vpc_id = aws_default_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "gj2026-event-sg" }
}

# ─────────────────────────────────────────────
# IAM Role: EC2 (CloudWatch + SSM + Lambda invoke 권한)
# ─────────────────────────────────────────────
resource "aws_iam_role" "ec2" {
  name = "gj2026-event-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_cw" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "ec2_extra" {
  name = "gj2026-event-ec2-extra"
  role = aws_iam_role.ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:PutParameter", "ssm:GetParameter"]
        Resource = "arn:aws:ssm:ap-northeast-2:${data.aws_caller_identity.current.account_id}:parameter/gj2026/*"
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = "arn:aws:lambda:ap-northeast-2:${data.aws_caller_identity.current.account_id}:function:gj2026-event-*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "gj2026-event-ec2-profile"
  role = aws_iam_role.ec2.name
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─────────────────────────────────────────────
# EC2: gj2026-event-ec2
# ─────────────────────────────────────────────
resource "aws_instance" "event" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.small"
  subnet_id              = aws_default_subnet.az[0].id
  vpc_security_group_ids = [aws_security_group.event.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  user_data = <<-EOF
#!/bin/bash
set -e

# Python, FastAPI, uvicorn 설치
dnf install -y python3 python3-pip
pip3 install fastapi uvicorn

# 배포 app.py 배치 (Cloud event handling 배포파일)
echo "${local.app_py_b64}" | base64 -d > /home/ec2-user/app.py
chown ec2-user:ec2-user /home/ec2-user/app.py

# 앱 로그 디렉터리
mkdir -p /var/log/gj2026

# systemd 서비스: gj2026-app
# Restart=no → 서비스 장애 시 자동 재시작 안 함 (CW Alarm 트리거 목적)
cat > /etc/systemd/system/gj2026-app.service << 'SVCEOF'
[Unit]
Description=GJ2026 FastAPI App
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/home/ec2-user
ExecStart=/usr/local/bin/uvicorn app:app --host 127.0.0.1 --port 8080
StandardOutput=append:/var/log/gj2026/app.log
StandardError=append:/var/log/gj2026/app.log
Restart=no
ExecStartPost=/bin/bash -c 'sleep 5 && aws lambda invoke --function-name gj2026-event-updater --region ap-northeast-2 --payload "{}" /tmp/updater-resp.json || true'

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable gj2026-app
systemctl start gj2026-app

# SSM Parameter Store 초기 백업
sleep 5
aws ssm put-parameter \
  --name "/gj2026/event/app-py" \
  --value "$(cat /home/ec2-user/app.py)" \
  --type String \
  --overwrite \
  --region ap-northeast-2 || true

# CloudWatch Agent 설치
dnf install -y amazon-cloudwatch-agent

# CW Agent 설정: 앱 로그 → /gj2026/event/app-logs 전송
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWEOF'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/gj2026/app.log",
            "log_group_name": "/gj2026/event/app-logs",
            "log_stream_name": "{instance_id}",
            "timestamp_format": "%Y-%m-%d %H:%M:%S"
          }
        ]
      }
    }
  }
}
CWEOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# 커스텀 메트릭 수집 스크립트 (app_process_count, 10초 간격)
cat > /usr/local/bin/put-app-metric.sh << 'METRICEOF'
#!/bin/bash
COUNT=$(systemctl is-active gj2026-app 2>/dev/null | grep -c '^active' || echo 0)
aws cloudwatch put-metric-data \
  --namespace "GJ2026/Events" \
  --metric-name "app_process_count" \
  --value "$COUNT" \
  --region ap-northeast-2
METRICEOF

chmod +x /usr/local/bin/put-app-metric.sh

# 매 분 6회 실행 (약 10초 간격)
cat > /etc/cron.d/app-metric << 'CRONEOF'
* * * * * root /usr/local/bin/put-app-metric.sh
* * * * * root sleep 10 && /usr/local/bin/put-app-metric.sh
* * * * * root sleep 20 && /usr/local/bin/put-app-metric.sh
* * * * * root sleep 30 && /usr/local/bin/put-app-metric.sh
* * * * * root sleep 40 && /usr/local/bin/put-app-metric.sh
* * * * * root sleep 50 && /usr/local/bin/put-app-metric.sh
CRONEOF
EOF

  tags = { Name = "gj2026-event-ec2" }
}

# ─────────────────────────────────────────────
# CloudWatch Log Groups
# ─────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/gj2026/event/app-logs"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "recovery" {
  name              = "/gj2026/event/recovery"
  retention_in_days = 7
}

# ─────────────────────────────────────────────
# SNS + CloudWatch Alarm: app_process_count < 1
# ─────────────────────────────────────────────
resource "aws_sns_topic" "alarm" {
  name = "gj2026-event-alarm-topic"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alarm.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

resource "aws_cloudwatch_metric_alarm" "app" {
  alarm_name          = "gj2026-event-app-alarm"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "app_process_count"
  namespace           = "GJ2026/Events"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "gj2026-app 프로세스 다운 감지"
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.alarm.arn]
}

# ─────────────────────────────────────────────
# SSM Parameter Store: /gj2026/event/app-py
# (초기 placeholder - EC2 userdata에서 실제 값으로 덮어씀)
# ─────────────────────────────────────────────
resource "aws_ssm_parameter" "app_py" {
  name  = "/gj2026/event/app-py"
  type  = "String"
  value = "# placeholder"

  lifecycle {
    ignore_changes = [value]
  }
}

# ─────────────────────────────────────────────
# IAM Role: Lambda
# ─────────────────────────────────────────────
resource "aws_iam_role" "lambda" {
  name = "gj2026-event-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_perms" {
  name = "gj2026-event-lambda-perms"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:PutParameter", "ssm:SendCommand", "ssm:GetCommandInvocation"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
        Resource = "*"
      }
    ]
  })
}

# ─────────────────────────────────────────────
# Lambda: gj2026-event-updater
# ─────────────────────────────────────────────
data "archive_file" "updater" {
  type        = "zip"
  output_path = "${path.module}/lambda/updater.zip"
  source {
    content  = file("${path.module}/lambda/updater.py")
    filename = "updater.py"
  }
}

resource "aws_lambda_function" "updater" {
  function_name    = "gj2026-event-updater"
  role             = aws_iam_role.lambda.arn
  handler          = "updater.lambda_handler"
  runtime          = "python3.12" # PDF 명세: python3.14
  filename         = data.archive_file.updater.output_path
  source_code_hash = data.archive_file.updater.output_base64sha256
  timeout          = 60

  tags = { Name = "gj2026-event-updater" }
}

resource "aws_cloudwatch_log_group" "updater" {
  name              = "/aws/lambda/gj2026-event-updater"
  retention_in_days = 7
}

# ─────────────────────────────────────────────
# Lambda: gj2026-event-recovery
# ─────────────────────────────────────────────
data "archive_file" "recovery" {
  type        = "zip"
  output_path = "${path.module}/lambda/recovery.zip"
  source {
    content  = file("${path.module}/lambda/recovery.py")
    filename = "recovery.py"
  }
}

resource "aws_lambda_function" "recovery" {
  function_name    = "gj2026-event-recovery"
  role             = aws_iam_role.lambda.arn
  handler          = "recovery.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.recovery.output_path
  source_code_hash = data.archive_file.recovery.output_base64sha256
  timeout          = 120

  tags = { Name = "gj2026-event-recovery" }
}

resource "aws_cloudwatch_log_group" "recovery_lambda" {
  name              = "/aws/lambda/gj2026-event-recovery"
  retention_in_days = 7
}

# ─────────────────────────────────────────────
# EventBridge Rule: gj2026-event-trigger-alarm
# CloudWatch Alarm ALARM 상태 → recovery Lambda 자동 실행
# ─────────────────────────────────────────────
resource "aws_cloudwatch_event_rule" "alarm_trigger" {
  name        = "gj2026-event-trigger-alarm"
  description = "CloudWatch Alarm ALARM 전환 시 recovery Lambda 실행"

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = ["gj2026-event-app-alarm"]
      state = {
        value = ["ALARM"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "recovery" {
  rule      = aws_cloudwatch_event_rule.alarm_trigger.name
  target_id = "gj2026-event-recovery"
  arn       = aws_lambda_function.recovery.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.recovery.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.alarm_trigger.arn
}

output "ec2_public_ip" {
  value = aws_instance.event.public_ip
}

output "alarm_name" {
  value = aws_cloudwatch_metric_alarm.app.alarm_name
}
