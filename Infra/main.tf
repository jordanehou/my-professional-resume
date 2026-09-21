terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "eu-north-1"
}

# Suffixe unique : le compte AWS est partage avec d'autres utilisateurs
variable "suffix" {
  type    = string
  default = "jordan"
}

provider "aws" {
  region = var.aws_region
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "resume_ecs_task_execution_role_${var.suffix}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecr_repository" "resume_repo" {
  name                 = "portfolio-repo-${var.suffix}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/portfolio-app-${var.suffix}"
  retention_in_days = 7
}

resource "aws_ecs_cluster" "resume_cluster" {
  name = "portfolio-cluster-${var.suffix}"
}

resource "aws_security_group" "ecs_sg" {
  name   = "resume-ecs-sg-${var.suffix}"
  vpc_id = data.aws_vpc.default.id

  ingress {
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
}

resource "aws_ecs_task_definition" "resume_task" {
  family                   = "portfolio-task-${var.suffix}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([{
    name         = "portfolio-app"
    image        = "nginx:alpine"
    essential    = true
    portMappings = [{ containerPort = 80, hostPort = 80, protocol = "tcp" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "resume_service" {
  name            = "portfolio-service-${var.suffix}"
  cluster         = aws_ecs_cluster.resume_cluster.id
  task_definition = aws_ecs_task_definition.resume_task.arn
  launch_type     = "FARGATE"
  desired_count   = 1

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    ignore_changes = [task_definition]
  }
}

output "ecr_repository_url" {
  value = aws_ecr_repository.resume_repo.repository_url
}

output "execution_role_arn" {
  value = aws_iam_role.ecs_task_execution_role.arn
}
