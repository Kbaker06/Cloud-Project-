data "aws_region" "current" {}

locals {
  container_name = var.name
}

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = var.tags
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  # Always keep `base` tasks on on-demand FARGATE; spread the rest by weight.
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 1
    weight            = var.use_fargate_spot ? 1 : 100
  }

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = var.use_fargate_spot ? 3 : 0
  }
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64" # Graviton: ~20% cheaper per vCPU-hour.
  }

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = var.image
      essential = true

      portMappings = [{
        containerPort = var.container_port
        protocol      = "tcp"
      }]

      environment = [for k, v in var.environment : { name = k, value = v }]
      secrets     = [for k, v in var.secrets : { name = k, valueFrom = v }]

      readonlyRootFilesystem = true
      user                   = "65532:65532"
      linuxParameters = {
        initProcessEnabled = true
        capabilities       = { drop = ["ALL"] }
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "app"
        }
      }
    }
  ])

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
resource "aws_security_group" "service" {
  name_prefix = "${var.name}-svc-"
  description = "${var.name} tasks: ingress only from the ALB"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-svc" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "from_alb" {
  security_group_id            = aws_security_group.service.id
  description                  = "App port from ALB"
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  referenced_security_group_id = var.alb_security_group_id
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.service.id
  description       = "Outbound (image pulls, AWS APIs, database)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_lb_target_group" "this" {
  name_prefix          = "tg-"
  port                 = var.container_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = var.health_check_path
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener_rule" "this" {
  listener_arn = var.alb_listener_arn
  priority     = var.listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  condition {
    path_pattern {
      values = var.path_patterns
    }
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "this" {
  name            = var.name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count

  enable_execute_command            = var.enable_execute_command
  health_check_grace_period_seconds = 30
  propagate_tags                    = "SERVICE"

  # Rolling deploy that never drops below 100% healthy capacity...
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # ...and automatically rolls back if the new task set can't get healthy.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 1
    weight            = var.use_fargate_spot ? 1 : 100
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = var.use_fargate_spot ? 3 : 0
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = local.container_name
    container_port   = var.container_port
  }

  # Autoscaling owns desired_count after the first apply.
  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [aws_lb_listener_rule.this, aws_ecs_cluster_capacity_providers.this]

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Autoscaling: target tracking on CPU and on requests-per-target
# ---------------------------------------------------------------------------
resource "aws_appautoscaling_target" "this" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.this.name}"
  min_capacity       = var.min_count
  max_capacity       = var.max_count
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  resource_id        = aws_appautoscaling_target.this.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target_percent
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "requests" {
  name               = "${var.name}-requests"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  resource_id        = aws_appautoscaling_target.this.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.requests_per_target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${var.alb_arn_suffix}/${aws_lb_target_group.this.arn_suffix}"
    }
  }
}

# ---------------------------------------------------------------------------
# Alarms
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "target_5xx_rate" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${var.name}-5xx-rate"
  alarm_description   = "More than 5% of requests to ${var.name} returned 5xx over 5 minutes."
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_sns_topic_arn]
  ok_actions          = [var.alarm_sns_topic_arn]

  metric_query {
    id          = "rate"
    expression  = "IF(requests > 0, 100 * errors / requests, 0)"
    label       = "5xx %"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = var.alb_arn_suffix
        TargetGroup  = aws_lb_target_group.this.arn_suffix
      }
    }
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = var.alb_arn_suffix
        TargetGroup  = aws_lb_target_group.this.arn_suffix
      }
    }
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${var.name}-unhealthy-hosts"
  alarm_description   = "At least one ${var.name} target is failing health checks."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_sns_topic_arn]
  ok_actions          = [var.alarm_sns_topic_arn]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = aws_lb_target_group.this.arn_suffix
  }

  tags = var.tags
}
