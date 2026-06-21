# =============================================================================
# 7.3 IAM Role
#  - Task Execution Role : ECR pull, CloudWatch Logs 전송
#  - Task Role           : DynamoDB 저장 권한
# =============================================================================

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ---- Task Execution Role ----
resource "aws_iam_role" "task_execution" {
  name               = "${local.prefix}-ecs-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json

  tags = {
    Name = "${local.prefix}-ecs-task-execution-role"
  }
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ---- Task Role (DynamoDB 저장 권한) ----
resource "aws_iam_role" "task" {
  name               = "${local.prefix}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json

  tags = {
    Name = "${local.prefix}-ecs-task-role"
  }
}

data "aws_iam_policy_document" "dynamodb_write" {
  statement {
    sid = "BookingTableAccess"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
      "dynamodb:BatchWriteItem",
      "dynamodb:DescribeTable"
    ]
    resources = [
      aws_dynamodb_table.booking.arn,
      "${aws_dynamodb_table.booking.arn}/index/*"
    ]
  }
}

resource "aws_iam_role_policy" "task_dynamodb" {
  name   = "${local.prefix}-dynamodb-access"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.dynamodb_write.json
}
