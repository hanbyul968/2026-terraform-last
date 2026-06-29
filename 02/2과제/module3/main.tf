terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.0" }
  }
}

# 2-3 Cloud event handling — eu-west-1
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

# ── EC2 (monitored) ──────────────────────────────────────────────────
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
  description = "minimal"
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

# ── SNS ──────────────────────────────────────────────────────────────
resource "aws_sns_topic" "alert" {
  name = "wsc2026-event-alert"
}

# ── Lambda (remediate + notify) ──────────────────────────────────────
resource "aws_iam_role" "lambda" {
  name = "wsc2026-event-lambda-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy" "lambda" {
  name = "remediate-min"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ec2:RevokeSecurityGroupIngress", "ec2:DescribeSecurityGroups"], Resource = "*" },
      { Effect = "Allow", Action = ["sns:Publish"], Resource = aws_sns_topic.alert.arn },
      { Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = "arn:aws:logs:*:*:*" }
    ]
  })
}
data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/handler.zip"
}
resource "aws_lambda_function" "remediate" {
  function_name    = "wsc2026-event-remediator"
  role             = aws_iam_role.lambda.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.14"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 30
  environment { variables = { TOPIC_ARN = aws_sns_topic.alert.arn } }
}
resource "aws_lambda_permission" "events" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediate.function_name
  principal     = "events.amazonaws.com"
}

# ── CloudTrail (R/W management events) ───────────────────────────────
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
  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }
  depends_on = [aws_s3_bucket_policy.trail]
}

# ── EventBridge rules (4) ────────────────────────────────────────────
locals {
  rules = {
    "wsc2026-sg-change-rule"       = ["AuthorizeSecurityGroupIngress"]
    "wsc2026-role-change-rule"     = ["AssociateIamInstanceProfile", "ReplaceIamInstanceProfileAssociation"]
    "wsc2026-ec2-terminate-rule"   = ["TerminateInstances"]
    "wsc2026-ec2-type-change-rule" = ["ModifyInstanceAttribute"]
  }
}
resource "aws_cloudwatch_event_rule" "r" {
  for_each = local.rules
  name     = each.key
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail      = { eventName = each.value }
  })
}
resource "aws_cloudwatch_event_target" "r" {
  for_each = local.rules
  rule     = aws_cloudwatch_event_rule.r[each.key].name
  arn      = aws_lambda_function.remediate.arn
}

output "sns_topic" { value = aws_sns_topic.alert.arn }
output "trail_bucket" { value = aws_s3_bucket.trail.id }
