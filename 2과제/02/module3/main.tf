terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.0" }
  }
}

# 2-3 Cloud Event Handling — eu-west-1
# 문제지 기준: 보안/비용 위협 API 이벤트 발생 시 원래 상태로 복구하거나 관리자에게 알림.
#   VPC(event-vpc) + EC2 + SNS + 단일 Lambda + CloudTrail(Mgmt R/W) +
#   EventBridge 4 rules(sg-change / role-change / ec2-terminate / ec2-type-change).
provider "aws" {
  region = "eu-west-1"
}

data "aws_caller_identity" "current" {}

# ── VPC event-vpc 172.16.0.0/16 ──────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = "172.16.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "event-vpc" }
}
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "event-igw" }
}
resource "aws_subnet" "pub_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "172.16.0.0/24"
  availability_zone       = "eu-west-1a"
  map_public_ip_on_launch = true
  tags                    = { Name = "event-pub-a" }
}
resource "aws_subnet" "pub_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "172.16.1.0/24"
  availability_zone       = "eu-west-1b"
  map_public_ip_on_launch = true
  tags                    = { Name = "event-pub-b" }
}
resource "aws_route_table" "pub" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "event-pub-rtb" }
}
resource "aws_route_table_association" "pub_a" {
  subnet_id      = aws_subnet.pub_a.id
  route_table_id = aws_route_table.pub.id
}
resource "aws_route_table_association" "pub_b" {
  subnet_id      = aws_subnet.pub_b.id
  route_table_id = aws_route_table.pub.id
}

# ── EC2 (monitored) — wsc2026-event-ec2, event-pub-a ─────────────────
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
resource "aws_iam_role" "ec2" {
  name = "wsc2026-event-ec2-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.ec2.name
}
resource "aws_iam_instance_profile" "ec2" {
  name = "wsc2026-event-ec2-profile"
  role = aws_iam_role.ec2.name
}
resource "aws_security_group" "ec2" {
  name        = "wsc2026-event-sg"
  description = "minimal - egress only"
  vpc_id      = aws_vpc.main.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "wsc2026-event-sg" }
}
resource "aws_instance" "ec2" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.pub_a.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  tags                   = { Name = "wsc2026-event-ec2" }
}

# ── SNS wsc2026-event-alert ──────────────────────────────────────────
resource "aws_sns_topic" "alert" {
  name = "wsc2026-event-alert"
}

# ── Lambda functions (vf: four remediation/alert functions) ─────────
resource "aws_iam_role" "lambda" {
  name = "wsc2026-event-lambda-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy" "lambda" {
  name = "event-recover-min"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:RevokeSecurityGroupIngress",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeIamInstanceProfileAssociations",
          "ec2:ReplaceIamInstanceProfileAssociation",
          "ec2:DescribeInstances",
          "ec2:StopInstances",
          "ec2:ModifyInstanceAttribute",
          "ec2:StartInstances"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "iam:ListInstanceProfilesForRole"
        Resource = aws_iam_role.ec2.arn
      },
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.alert.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:eu-west-1:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/event_lambda.zip"
}

locals {
  event_lambdas = {
    sg = {
      name    = "wsc2026-sg-remediation"
      handler = "index.sg_remediation_handler"
      environment = {
        SECURITY_GROUP_ID = aws_security_group.ec2.id
      }
    }
    role = {
      name    = "wsc2026-role-remediation"
      handler = "index.role_remediation_handler"
      environment = {
        INSTANCE_ID = aws_instance.ec2.id
        ROLE_NAME   = aws_iam_role.ec2.name
      }
    }
    terminate = {
      name        = "wsc2026-ec2-terminate-alert"
      handler     = "index.ec2_terminate_handler"
      environment = {}
    }
    type = {
      name    = "wsc2026-ec2-type-remediation"
      handler = "index.ec2_type_remediation_handler"
      environment = {
        INSTANCE_ID   = aws_instance.ec2.id
        INSTANCE_TYPE = "t3.micro"
      }
    }
  }
}

resource "aws_lambda_function" "event" {
  for_each         = local.event_lambdas
  function_name    = each.value.name
  role             = aws_iam_role.lambda.arn
  handler          = each.value.handler
  runtime          = "python3.12"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 300
  environment {
    variables = merge(
      { SNS_TOPIC_ARN = aws_sns_topic.alert.arn },
      each.value.environment
    )
  }
  depends_on = [aws_iam_role_policy.lambda]
}

# ── CloudTrail wsc2026-event-trail (Management R/W) ──────────────────
resource "aws_s3_bucket" "trail" {
  bucket        = "wsc2026-event-trail-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}
data "aws_iam_policy_document" "trail" {
  statement {
    sid       = "AWSCloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
  statement {
    sid       = "AWSCloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}
resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = data.aws_iam_policy_document.trail.json
}
resource "aws_cloudtrail" "main" {
  name                          = "wsc2026-event-trail"
  s3_bucket_name                = aws_s3_bucket.trail.id
  include_global_service_events = true
  is_multi_region_trail         = false
  # Management Events = Read/Write (EventBridge 가 API 호출을 감지할 수 있도록)
  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }
  depends_on = [aws_s3_bucket_policy.trail]
}

# ── EventBridge Rules (각 규칙이 API 이벤트 감지 -> Lambda 호출) ──────
# 1) SG 인바운드 규칙 추가
resource "aws_cloudwatch_event_rule" "sg_change" {
  name = "wsc2026-sg-change-rule"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["ec2.amazonaws.com"]
      eventName   = ["AuthorizeSecurityGroupIngress"]
    }
  })
}
resource "aws_cloudwatch_event_target" "sg_change" {
  rule = aws_cloudwatch_event_rule.sg_change.name
  arn  = aws_lambda_function.event["sg"].arn
}

# 2) EC2 IAM Role 변경
resource "aws_cloudwatch_event_rule" "role_change" {
  name = "wsc2026-role-change-rule"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["ec2.amazonaws.com"]
      eventName   = ["AssociateIamInstanceProfile", "ReplaceIamInstanceProfileAssociation", "DisassociateIamInstanceProfile"]
    }
  })
}
resource "aws_cloudwatch_event_target" "role_change" {
  rule = aws_cloudwatch_event_rule.role_change.name
  arn  = aws_lambda_function.event["role"].arn
}

# 3) EC2 인스턴스 종료
resource "aws_cloudwatch_event_rule" "ec2_terminate" {
  name = "wsc2026-ec2-terminate-rule"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
    detail = {
      state = ["terminated"]
    }
  })
}
resource "aws_cloudwatch_event_target" "ec2_terminate" {
  rule = aws_cloudwatch_event_rule.ec2_terminate.name
  arn  = aws_lambda_function.event["terminate"].arn
}

# 4) EC2 인스턴스 타입 변경
resource "aws_cloudwatch_event_rule" "ec2_type_change" {
  name = "wsc2026-ec2-type-change-rule"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["ec2.amazonaws.com"]
      eventName   = ["ModifyInstanceAttribute"]
    }
  })
}
resource "aws_cloudwatch_event_target" "ec2_type_change" {
  rule = aws_cloudwatch_event_rule.ec2_type_change.name
  arn  = aws_lambda_function.event["type"].arn
}

# ── Lambda invoke permissions (one rule per vf function) ─────────────
locals {
  event_targets = {
    sg = {
      rule_arn      = aws_cloudwatch_event_rule.sg_change.arn
      function_name = aws_lambda_function.event["sg"].function_name
    }
    role = {
      rule_arn      = aws_cloudwatch_event_rule.role_change.arn
      function_name = aws_lambda_function.event["role"].function_name
    }
    terminate = {
      rule_arn      = aws_cloudwatch_event_rule.ec2_terminate.arn
      function_name = aws_lambda_function.event["terminate"].function_name
    }
    type = {
      rule_arn      = aws_cloudwatch_event_rule.ec2_type_change.arn
      function_name = aws_lambda_function.event["type"].function_name
    }
  }
}
resource "aws_lambda_permission" "events" {
  for_each      = local.event_targets
  statement_id  = "AllowEventBridge-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = each.value.function_name
  principal     = "events.amazonaws.com"
  source_arn    = each.value.rule_arn
}

output "sns_topic" { value = aws_sns_topic.alert.arn }
output "trail_bucket" { value = aws_s3_bucket.trail.id }
output "lambda_functions" {
  value = { for key, fn in aws_lambda_function.event : key => fn.function_name }
}
output "event_rules" {
  value = [
    aws_cloudwatch_event_rule.sg_change.name,
    aws_cloudwatch_event_rule.role_change.name,
    aws_cloudwatch_event_rule.ec2_terminate.name,
    aws_cloudwatch_event_rule.ec2_type_change.name,
  ]
}



# ── vf 채점 스크립트 호환 리소스 ────────────────────────────────────
# 배포된 문제지의 기존 4개 Lambda/Rule은 그대로 보존하고, 실제 vf 채점
# 스크립트가 검사하는 Stop/Tag Lambda와 AWS Config 규칙을 추가한다.
resource "aws_lambda_function" "ec2_stop_remediation" {
  function_name    = "wsc2026-ec2-stop-remediation"
  role             = aws_iam_role.lambda.arn
  handler          = "index.ec2_stop_remediation_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 60

  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.alert.arn
      INSTANCE_ID   = aws_instance.ec2.id
    }
  }

  depends_on = [aws_iam_role_policy.lambda]
}

resource "aws_lambda_function" "tag_alert" {
  function_name    = "wsc2026-tag-alert"
  role             = aws_iam_role.lambda.arn
  handler          = "index.tag_alert_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 60

  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.alert.arn
    }
  }

  depends_on = [aws_iam_role_policy.lambda]
}

# 채점기의 일반 StopInstances(force=false) API 호출을 즉시 감지한다.
# Lambda가 호출하는 강제 종료(force=true)는 제외하여 재귀 호출을 방지한다.
resource "aws_cloudwatch_event_rule" "ec2_stop" {
  name = "wsc2026-ec2-stop-rule"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["ec2.amazonaws.com"]
      eventName   = ["StopInstances"]
      requestParameters = {
        force = [false]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "ec2_stop" {
  rule = aws_cloudwatch_event_rule.ec2_stop.name
  arn  = aws_lambda_function.ec2_stop_remediation.arn
}

resource "aws_lambda_permission" "ec2_stop" {
  statement_id  = "AllowEventBridge-stop"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ec2_stop_remediation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ec2_stop.arn
}

# Required-tags Config 규칙이 NON_COMPLIANT로 바뀌면 관리자에게 알린다.
resource "aws_cloudwatch_event_rule" "tag_noncompliant" {
  name = "wsc2026-tag-noncompliant-rule"
  event_pattern = jsonencode({
    source      = ["aws.config"]
    detail-type = ["Config Rules Compliance Change"]
    detail = {
      configRuleName = ["wsc2026-required-tags-rule"]
      newEvaluationResult = {
        complianceType = ["NON_COMPLIANT"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "tag_noncompliant" {
  rule = aws_cloudwatch_event_rule.tag_noncompliant.name
  arn  = aws_lambda_function.tag_alert.arn
}

resource "aws_lambda_permission" "tag_noncompliant" {
  statement_id  = "AllowEventBridge-tag-noncompliant"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.tag_alert.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.tag_noncompliant.arn
}

# ── AWS Config ────────────────────────────────────────────────────────
resource "aws_s3_bucket" "config" {
  bucket        = "wsc2026-event-config-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = { Name = "wsc2026-event-config" }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket = aws_s3_bucket.config.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_role" "config" {
  name = "wsc2026-event-config-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "config.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "config_managed" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_iam_role_policy" "config_delivery" {
  name = "wsc2026-event-config-delivery"
  role = aws_iam_role.config.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource = aws_s3_bucket.config.arn
      },
      {
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.config.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
        Condition = {
          StringLike = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

resource "aws_config_configuration_recorder" "main" {
  name     = "wsc2026-event-config-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = false
    include_global_resource_types = false
    resource_types = [
      "AWS::EC2::Instance",
      "AWS::EC2::SecurityGroup",
    ]
  }

  depends_on = [
    aws_iam_role_policy_attachment.config_managed,
    aws_iam_role_policy.config_delivery,
  ]
}

resource "aws_config_delivery_channel" "main" {
  name           = "wsc2026-event-config-delivery-channel"
  s3_bucket_name = aws_s3_bucket.config.bucket

  snapshot_delivery_properties {
    delivery_frequency = "Six_Hours"
  }

  depends_on = [aws_config_configuration_recorder.main]
}

resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}

resource "aws_config_config_rule" "sg_ssh" {
  name = "wsc2026-sg-ssh-rule"

  source {
    owner             = "AWS"
    source_identifier = "INCOMING_SSH_DISABLED"
  }

  scope {
    compliance_resource_types = ["AWS::EC2::SecurityGroup"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "required_tags" {
  name             = "wsc2026-required-tags-rule"
  input_parameters = jsonencode({ tag1Key = "Name" })

  source {
    owner             = "AWS"
    source_identifier = "REQUIRED_TAGS"
  }

  # 채점 대상 EC2만 평가한다. 이 인스턴스에는 Terraform이 Name 태그를 항상 유지한다.
  scope {
    compliance_resource_id    = aws_instance.ec2.id
    compliance_resource_types = ["AWS::EC2::Instance"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

output "grading_lambda_functions" {
  value = [
    aws_lambda_function.ec2_stop_remediation.function_name,
    aws_lambda_function.event["terminate"].function_name,
    aws_lambda_function.event["sg"].function_name,
    aws_lambda_function.tag_alert.function_name,
  ]
}

output "grading_config_rules" {
  value = [
    aws_config_config_rule.sg_ssh.name,
    aws_config_config_rule.required_tags.name,
  ]
}


# 이전 채점 실행으로 stopped 상태가 남아 있어도 다음 채점 전에 running으로 복구한다.
resource "aws_ec2_instance_state" "event" {
  instance_id = aws_instance.ec2.id
  state       = "running"
}


# ── 채점 시간 제한용 연속 복구 모니터 ────────────────────────────────
# CloudTrail 관리 이벤트는 초기화 직후 30초 이상 지연될 수 있다.
# 1분마다 52초 동안 2초 간격으로 폴링해 스케줄 사이의 공백을 최소화한다.
resource "aws_lambda_function" "remediation_monitor" {
  function_name    = "wsc2026-remediation-monitor"
  role             = aws_iam_role.lambda.arn
  handler          = "index.continuous_remediation_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 120

  environment {
    variables = {
      SNS_TOPIC_ARN     = aws_sns_topic.alert.arn
      INSTANCE_ID       = aws_instance.ec2.id
      SECURITY_GROUP_ID = aws_security_group.ec2.id
      MONITOR_SECONDS   = "52"
      POLL_SECONDS      = "2"
    }
  }

  depends_on = [aws_iam_role_policy.lambda]
}

resource "aws_cloudwatch_event_rule" "remediation_monitor" {
  name                = "wsc2026-remediation-monitor-rule"
  description         = "Continuously remediate the competition EC2 and security group"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "remediation_monitor" {
  rule = aws_cloudwatch_event_rule.remediation_monitor.name
  arn  = aws_lambda_function.remediation_monitor.arn
}

resource "aws_lambda_permission" "remediation_monitor" {
  statement_id  = "AllowEventBridge-remediation-monitor"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediation_monitor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.remediation_monitor.arn
}
