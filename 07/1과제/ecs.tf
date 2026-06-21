resource "aws_ecr_repository" "book" {
  name                 = "skills-book-app"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  tags                 = { Name = "skills-book-ecr" }
}

resource "null_resource" "docker_push" {
  depends_on = [aws_ecr_repository.book]

  provisioner "local-exec" {
    command = <<-EOT
      aws ecr get-login-password --region ap-northeast-2 | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.ap-northeast-2.amazonaws.com
      docker build -t skills-book-app ${path.module}/app
      docker tag skills-book-app:latest ${aws_ecr_repository.book.repository_url}:latest
      docker push ${aws_ecr_repository.book.repository_url}:latest
    EOT
  }
}

resource "aws_ecs_cluster" "main" {
  name = "skills-book-cluster"
  tags = { Name = "skills-book-cluster" }
}

resource "aws_ecs_task_definition" "book" {
  family                   = "skills-book-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "skills-book-container"
    image     = "${aws_ecr_repository.book.repository_url}:latest"
    essential = true
    portMappings = [{ containerPort = 8080, protocol = "tcp" }]
    environment = [
      { name = "AWS_REGION", value = "ap-northeast-2" },
      { name = "TABLE_NAME", value = "skills-book-booking" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/skills-book-app"
        "awslogs-region"        = "ap-northeast-2"
        "awslogs-stream-prefix" = "book"
      }
    }
  }])
}

resource "aws_ecs_service" "book" {
  name            = "skills-book-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.book.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.all.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ecs.arn
    container_name   = "skills-book-container"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.http, null_resource.docker_push]
  tags       = { Name = "skills-book-service" }
}
