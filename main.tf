locals {
  name_prefix = var.name
  tags        = merge({
    "Name"        = var.name,
    "Environment" = var.environment,
    "ManagedBy"   = "Terraform"
  }, var.tags)
}

# CloudWatch Log Group (one per service)
resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

# ECS Cluster
resource "aws_ecs_cluster" "this" {
  name = local.name_prefix

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enabled" : "disabled"
  }

  configuration {
    execute_command_configuration {
      logging    = var.enable_execute_command ? "OVERRIDE" : "DEFAULT"
      log_configuration {
        cloud_watch_log_group_name = var.enable_execute_command ? aws_cloudwatch_log_group.this.name : null
      }
    }
  }

  tags = local.tags
}

# Security Groups
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "ALB security group"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.alb_allowed_ingress_cidrs
    content {
      description = "HTTP/HTTPS from allowed CIDR"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_security_group" "service" {
  name        = "${local.name_prefix}-svc-sg"
  description = "Service tasks security group"
  vpc_id      = var.vpc_id

  # Allow traffic from ALB to the container port
  ingress {
    description      = "ALB to service"
    from_port        = var.container_port
    to_port          = var.container_port
    protocol         = "tcp"
    security_groups  = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

# Application Load Balancer
resource "aws_lb" "this" {
  name               = substr("${local.name_prefix}-alb", 0, 32)
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids
  idle_timeout       = var.alb_idle_timeout
  internal           = var.alb_internal
  ip_address_type    = var.alb_ip_address_type
  tags               = local.tags
}

# Target Group
resource "aws_lb_target_group" "this" {
  name        = substr("${local.name_prefix}-tg", 0, 32)
  port        = var.container_port
  protocol    = var.alb_protocol
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    enabled             = true
    path                = var.health_check_path
    matcher             = var.health_check_matcher
    interval            = var.health_check_interval
    healthy_threshold   = var.health_check_healthy_threshold
    unhealthy_threshold = var.health_check_unhealthy_threshold
    timeout             = var.health_check_timeout
  }

  deregistration_delay = var.tg_deregistration_delay

  stickiness {
    type            = var.tg_stickiness_type
    cookie_duration = var.tg_stickiness_cookie_duration
    enabled         = var.tg_enable_stickiness
  }

  tags = local.tags
}

# Listeners (HTTP -> redirect to HTTPS) and HTTPS
resource "aws_lb_listener" "http" {
  count             = var.enable_http_redirect ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.listener_ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# Optional listener rules (host/path based)
resource "aws_lb_listener_rule" "paths" {
  count        = length(var.listener_rules)
  listener_arn = aws_lb_listener.https.arn
  priority     = var.listener_rules[count.index].priority

  dynamic "condition" {
    for_each = var.listener_rules[count.index].hosts
    content {
      host_header { values = [condition.value] }
    }
  }

  dynamic "condition" {
    for_each = var.listener_rules[count.index].paths
    content {
      path_pattern { values = [condition.value] }
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# IAM: Task Execution Role
resource "aws_iam_role" "execution" {
  name               = "${local.name_prefix}-exec"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "execution_default" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "extra_exec_permissions" {
  count = length(var.extra_execution_role_policy_json) > 0 ? 1 : 0
  name  = "${local.name_prefix}-exec-extra"
  role  = aws_iam_role.execution.id
  policy = var.extra_execution_role_policy_json
}

# IAM: Task Role (application permissions)
resource "aws_iam_role" "task" {
  name               = "${local.name_prefix}-task"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "task_inline" {
  count  = length(var.task_role_inline_policy_json) > 0 ? 1 : 0
  name   = "${local.name_prefix}-task-inline"
  role   = aws_iam_role.task.id
  policy = var.task_role_inline_policy_json
}

# Task Definition
resource "aws_ecs_task_definition" "this" {
  family                   = local.name_prefix
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  network_mode             = "awsvpc"
  requires_compatibilities = var.capacity_providers
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  runtime_platform {
    operating_system_family = var.operating_system_family
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name      = var.container_name
      image     = var.container_image
      essential = true
      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
          appProtocol   = var.app_protocol
        }
      ]
      environment = [for k, v in var.environment : { name = k, value = v }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = var.region
          awslogs-stream-prefix = var.container_name
        }
      }
      readonlyRootFilesystem = var.readonly_root_fs
      healthCheck = var.container_healthcheck
      secrets = [for s in var.secrets : {
        name      = s.name
        valueFrom = s.value_from
      }]
    }
  ])
}

# ECS Service
resource "aws_ecs_service" "this" {
  name            = local.name_prefix
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = null # use capacity providers
  platform_version = var.platform_version
  enable_execute_command = var.enable_execute_command

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [aws_security_group.service.id]
    assign_public_ip = var.assign_public_ip
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = var.container_name
    container_port   = var.container_port
  }

  deployment_controller {
    type = var.deployment_controller_type
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  propagate_tags = "SERVICE"
  tags           = local.tags
}

# Capacity provider strategy (FARGATE / FARGATE_SPOT)
resource "aws_ecs_service" "capacity_providers_patch" {
  count           = var.enable_capacity_provider_strategy ? 1 : 0
  name            = aws_ecs_service.this.name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = var.capacity_provider_weights["FARGATE"]
    base              = var.capacity_provider_base
  }

  dynamic "capacity_provider_strategy" {
    for_each = contains(var.capacity_providers, "FARGATE_SPOT") ? [1] : []
    content {
      capacity_provider = "FARGATE_SPOT"
      weight            = var.capacity_provider_weights["FARGATE_SPOT"]
    }
  }

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [aws_security_group.service.id]
    assign_public_ip = var.assign_public_ip
  }

  deployment_controller {
    type = var.deployment_controller_type
  }

  depends_on = [aws_ecs_service.this]
  lifecycle { create_before_destroy = true }
}

# Application Auto Scaling for ECS Service desired count
resource "aws_appautoscaling_target" "this" {
  max_capacity       = var.asg_max_capacity
  min_capacity       = var.asg_min_capacity
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${local.name_prefix}-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  service_namespace  = aws_appautoscaling_target.this.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.asg_cpu_target
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    scale_in_cooldown  = var.asg_scale_in_cooldown
    scale_out_cooldown = var.asg_scale_out_cooldown
  }
}

resource "aws_appautoscaling_policy" "memory" {
  name               = "${local.name_prefix}-mem"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  service_namespace  = aws_appautoscaling_target.this.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.asg_memory_target
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    scale_in_cooldown  = var.asg_scale_in_cooldown
    scale_out_cooldown = var.asg_scale_out_cooldown
  }
}