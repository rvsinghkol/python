# =====================================================================
# ECS Fargate: cluster, IAM roles, task definition, service
# =====================================================================

resource "aws_ecs_cluster" "main" {
  name = "${local.name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name}"
  retention_in_days = var.log_retention_days
}

# ---------- IAM ----------
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Used by ECS itself: pull image from ECR, write logs
resource "aws_iam_role" "execution" {
  name               = "${local.name}-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Used by YOUR application code. Add policies here if the app calls AWS (S3, SQS...)
resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# ---------- Image ----------
data "aws_ecr_repository" "app" {
  name = var.ecr_repo_name
}

# Fails the plan early if the requested tag does not exist in ECR
data "aws_ecr_image" "app" {
  repository_name = var.ecr_repo_name
  image_tag       = var.image_tag
}

# ---------- Task definition (new revision per deploy/rollback) ----------
resource "aws_ecs_task_definition" "app" {
  family                   = "${local.name}-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  skip_destroy             = true # keep old revisions as history

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name         = var.app_name
    image        = "${data.aws_ecr_repository.app.repository_url}:${data.aws_ecr_image.app.image_tag}"
    essential    = true
    portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]

    # Plain settings. For passwords/DB URLs use "secrets" with Secrets Manager (see README).
    environment = [
      { name = "APP_ENV", value = var.environment }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "app"
      }
    }
  }])
}

# ---------- Service ----------
resource "aws_ecs_service" "app" {
  name                               = "${local.name}-service"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.app.arn
  desired_count                      = var.desired_count
  launch_type                        = "FARGATE"
  platform_version                   = "LATEST"
  health_check_grace_period_seconds  = 120 # Tomcat start-up time
  deployment_minimum_healthy_percent = 100 # never drop below current capacity
  deployment_maximum_percent         = 200 # start new tasks before stopping old
  propagate_tags                     = "SERVICE"
  wait_for_steady_state              = true # terraform apply waits until healthy

  deployment_circuit_breaker {
    enable   = true
    rollback = true # automatic rollback if new tasks keep failing
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = var.app_name
    container_port   = var.container_port
  }

  lifecycle {
    ignore_changes = [desired_count] # autoscaling owns this after creation
  }

  timeouts {
    create = "20m"
    update = "20m"
  }

  depends_on = [
    aws_lb_listener.http,
    aws_iam_role_policy_attachment.execution,
    aws_route.private_nat,
    aws_vpc_endpoint.interface,
    aws_vpc_endpoint.s3,
  ]
}
