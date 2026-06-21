# =============================================================================
# 7. ECS (Fargate) + 10. CloudWatch Logs
# =============================================================================

# ---- 10. CloudWatch Logs 로그 그룹 (고정 이름) ----
resource "aws_cloudwatch_log_group" "app" {
  name              = var.log_group_name # /skillskorea/ecs/app
  retention_in_days = 14

  tags = {
    Name = "${local.prefix}-ecs-log-group"
  }
}

# ---- 7.1 ECS Cluster ----
resource "aws_ecs_cluster" "book" {
  name = "${local.prefix}-book-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = {
    Name = "${local.prefix}-book-cluster"
  }
}

resource "aws_ecs_cluster_capacity_providers" "book" {
  cluster_name       = aws_ecs_cluster.book.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# ---- 7.2 Task Definition ----
resource "aws_ecs_task_definition" "book" {
  family                   = "${local.prefix}-book-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu    # 256
  memory                   = var.task_memory # 512
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64" # Linux/AMD64
  }

  container_definitions = jsonencode([
    {
      name      = "book"
      image     = local.image_uri
      essential = true

      portMappings = [
        {
          containerPort = var.container_port # 8080
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "AWS_REGION", value = var.region },
        { name = "TABLE_NAME", value = local.table_name }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = var.log_group_name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  depends_on = [null_resource.docker_build_push]

  tags = {
    Name = "${local.prefix}-book-task"
  }
}

# ---- 7.4 ECS Service ----
resource "aws_ecs_service" "book" {
  name            = "${local.prefix}-book-service"
  cluster         = aws_ecs_cluster.book.id
  task_definition = aws_ecs_task_definition.book.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.book.arn
    container_name   = "book"
    container_port   = var.container_port
  }

  depends_on = [
    aws_lb_listener.http,
    aws_iam_role_policy.task_dynamodb
  ]

  tags = {
    Name = "${local.prefix}-book-service"
  }
}
