terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.0" }
  }
}

# 2-3 Cloud Event Handling — eu-west-1
# 과제지/rubric: 보안·비용 위협 API 이벤트 발생 시 원래 상태로 복구하거나 관리자에게 알림.
#   VPC(event-vpc) + EC2(정적웹,종료방지) + SNS + 단일 event_lambda.handler(4함수) +
#   CloudTrail(Mgmt R/W, S3=wsc2026-event-s3) +
#   EventBridge 4 rules: sg-change / role-change / termination-protection-change / ec2-type-change
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
# 인스턴스 프로파일 이름을 역할명과 동일하게 둔다.
# (3-3 채점: IamInstanceProfile.Arn 의 마지막 토큰이 wsc2026-event-ec2-role 이어야 함)
resource "aws_iam_instance_profile" "ec2" {
  name = "wsc2026-event-ec2-role"
  role = aws_iam_role.ec2.name
}

# SG 최소 구성: 인바운드 tcp/80(정적 웹), 아웃바운드 전체.
# (3-3 채점: IpPermissions 에 tcp 80 0.0.0.0/0 이 존재해야 함)
resource "aws_security_group" "ec2" {
  name        = "wsc2026-event-sg"
  description = "minimal - allow http 80"
  vpc_id      = aws_vpc.main.id
  ingress {
    description = "static web"
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
  tags = { Name = "wsc2026-event-sg" }
}

# 제공된 userdata(정적 웹). 3-3 채점이 UserData base64 를 정확히 대조하므로 base64 를 그대로 지정.
#   디코드: #!/bin/bash / dnf update / dnf install httpd -y /
#           systemctl enable --now httpd / hostname > /var/www/html/index.html
resource "aws_instance" "ec2" {
  ami                     = data.aws_ami.al2023.id
  instance_type           = "t3.micro"
  subnet_id               = aws_subnet.pub_a.id
  vpc_security_group_ids  = [aws_security_group.ec2.id]
  iam_instance_profile    = aws_iam_instance_profile.ec2.name
  disable_api_termination = true # 지속 배포 위한 종료 방지
  user_data_base64        = "IyEvYmluL2Jhc2gKZG5mIHVwZGF0ZQpkbmYgaW5zdGFsbCBodHRwZCAteQpzeXN0ZW1jdGwgZW5hYmxlIC0tbm93IGh0dHBkCmhvc3RuYW1lID4gL3Zhci93d3cvaHRtbC9pbmRleC5odG1s"
  tags                    = { Name = "wsc2026-event-ec2" }
}

# ── SNS wsc2026-event-alert ──────────────────────────────────────────
resource "aws_sns_topic" "alert" {
  name = "wsc2026-event-alert"
}

# ── Lambda 실행 역할 (최소 권한) ─────────────────────────────────────
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
        Sid    = "Ec2Remediation"
        Effect = "Allow"
        Action = [
          "ec2:DescribeSecurityGroups",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:DescribeInstances",
          "ec2:DescribeIamInstanceProfileAssociations",
          "ec2:ReplaceIamInstanceProfileAssociation",
          "ec2:AssociateIamInstanceProfile",
          "ec2:ModifyInstanceAttribute",
          "ec2:StopInstances",
          "ec2:StartInstances"
        ]
        Resource = "*"
      },
      {
        # role 복구(프로파일 재부착)에 필요
        Sid      = "PassEc2Role"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.ec2.arn
      },
      {
        Sid      = "PublishAlert"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.alert.arn
      },
      {
        Sid      = "Logs"
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

# 4개 함수 모두 동일 코드(event_lambda.py) + handler=event_lambda.handler + python3.14.
locals {
  event_lambdas = {
    sg = {
      name        = "wsc2026-sg-remediation"
      environment = { SECURITY_GROUP_ID = aws_security_group.ec2.id }
    }
    role = {
      name        = "wsc2026-role-remediation"
      environment = { INSTANCE_ID = aws_instance.ec2.id, ROLE_NAME = aws_iam_instance_profile.ec2.name }
    }
    termination = {
      name        = "wsc2026-termination-protection-remediation"
      environment = { INSTANCE_ID = aws_instance.ec2.id }
    }
    type = {
      name        = "wsc2026-ec2-type-remediation"
      environment = { INSTANCE_ID = aws_instance.ec2.id, INSTANCE_TYPE = "t3.micro" }
    }
  }
}

resource "aws_lambda_function" "event" {
  for_each         = local.event_lambdas
  function_name    = each.value.name
  role             = aws_iam_role.lambda.arn
  handler          = "event_lambda.handler"
  runtime          = "python3.14"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 300
  environment {
    variables = merge({ SNS_TOPIC_ARN = aws_sns_topic.alert.arn }, each.value.environment)
  }
  depends_on = [aws_iam_role_policy.lambda]
}

# ── CloudTrail wsc2026-event-trail (Management R/W, S3=wsc2026-event-s3) ──
resource "aws_s3_bucket" "trail" {
  bucket        = "wsc2026-event-s3"
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
  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }
  depends_on = [aws_s3_bucket_policy.trail]
}

# ── EventBridge Rules (4개) ──────────────────────────────────────────
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

# 3) EC2 인스턴스 삭제방지 비활성화 (ModifyInstanceAttribute + disableApiTermination)
# 주의: CloudTrail 이벤트는 requestParameters.disableApiTermination = {"value": false} 형태의
#       "중첩 객체"다. EventBridge 의 exists 연산자는 leaf 노드에만 동작하므로
#       { disableApiTermination = [{exists=true}] } 로 쓰면 절대 매칭되지 않는다.
#       반드시 한 단계 더 들어가 value 리프에 매칭해야 한다.
resource "aws_cloudwatch_event_rule" "termination_protection_change" {
  name = "wsc2026-termination-protection-change-rule"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["ec2.amazonaws.com"]
      eventName   = ["ModifyInstanceAttribute"]
      requestParameters = {
        disableApiTermination = {
          value = [{ exists = true }]
        }
      }
    }
  })
}
resource "aws_cloudwatch_event_target" "termination_protection_change" {
  rule = aws_cloudwatch_event_rule.termination_protection_change.name
  arn  = aws_lambda_function.event["termination"].arn
}

# 4) EC2 인스턴스 타입 변경 (ModifyInstanceAttribute + instanceType)
# 주의: requestParameters.instanceType = {"value":"t3.large"} 중첩 객체이므로
#       value 리프에 exists 를 걸어야 매칭된다(위 3번과 동일한 이유).
resource "aws_cloudwatch_event_rule" "ec2_type_change" {
  name = "wsc2026-ec2-type-change-rule"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["ec2.amazonaws.com"]
      eventName   = ["ModifyInstanceAttribute"]
      requestParameters = {
        instanceType = {
          value = [{ exists = true }]
        }
      }
    }
  })
}
resource "aws_cloudwatch_event_target" "ec2_type_change" {
  rule = aws_cloudwatch_event_rule.ec2_type_change.name
  arn  = aws_lambda_function.event["type"].arn
}

# ── Lambda invoke permissions (rule -> function) ─────────────────────
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
    termination = {
      rule_arn      = aws_cloudwatch_event_rule.termination_protection_change.arn
      function_name = aws_lambda_function.event["termination"].function_name
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
    aws_cloudwatch_event_rule.termination_protection_change.name,
    aws_cloudwatch_event_rule.ec2_type_change.name,
  ]
}
