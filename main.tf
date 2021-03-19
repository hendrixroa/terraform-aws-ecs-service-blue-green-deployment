//  AWS ECS Service to run the task definition
resource "aws_ecs_service" "main" {
  count = 1
  name                 = var.name
  cluster              = var.cluster
  task_definition      = var.use_cloudwatch_logs ? aws_ecs_task_definition.main_cloudwatch[count.index].arn : aws_ecs_task_definition.main_elasticsearch_logs[count.index].arn
  scheduling_strategy  = "REPLICA"
  desired_count        = var.service_count
  force_new_deployment = true

  network_configuration {
    security_groups  = var.security_groups
    subnets          = var.subnets
    assign_public_ip = var.public_ip
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.blue.arn
    container_name   = var.name
    container_port   = var.port
  }

  depends_on = [
    aws_lb_listener.main_blue_green,
  ]

  lifecycle {
    ignore_changes = [
      load_balancer,
      desired_count,
      task_definition,
    ]
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 100
    base              = 1
  }

  deployment_controller {
    type = "CODE_DEPLOY"
  }
}

resource "aws_ecs_task_definition" "main_cloudwatch" {
  count = var.use_cloudwatch_logs ? 1 : 0
  family                   = "${var.name}-service"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  execution_role_arn       = var.roleExecArn
  task_role_arn            = var.roleArn
  cpu                      = var.cpu_unit
  memory                   = var.memory
  container_definitions    = jsonencode(local.mainContainerDefinition)
}

resource "aws_ecs_task_definition" "main_elasticsearch_logs" {
  count = var.use_cloudwatch_logs ? 0 : 1
  family                   = "${var.name}-service"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  execution_role_arn       = var.roleExecArn
  task_role_arn            = var.roleArn
  cpu                      = var.cpu_unit
  memory                   = var.memory
  container_definitions    = jsonencode(local.firelensContainerDefinition)
}

locals {
  main_environment = [
    {
      name  = "DATABASE_LOG_LEVEL"
      value = var.database_log_level
    },
    {
      name  = "APP"
      value = var.name
    },
    {
      name  = "LOG_LEVEL"
      value = var.log_level
    },
    {
      name  = "PORT"
      value = tostring(var.port)
    },
    {
      name  = "NEW_RELIC_APP_NAME"
      value = var.name
    }
  ]
  cloudwatch_logs_options = {
    awslogs-region        = var.region
    awslogs-group         = var.name
    awslogs-stream-prefix = var.prefix_logs
  }
  firelens_logs_options = {
    Name       = "es"
    Host       = var.es_url
    Port       = "443"
    Index      = lower(var.name)
    Type       = "${lower(var.name)}_type"
    Aws_Auth   = "On"
    Aws_Region = var.region
    tls        = "On"
  }
  mainContainerDefinition = [
    {
      essential = true
      image     = var.ecr_image_url
      name      = var.name
      portMappings = [
        {
          containerPort = var.port
          hostPort      = var.port
        }
      ]
      logConfiguration = {
        logDriver = var.use_cloudwatch_logs ? "awslogs" : "awsfirelens"
        options   = var.use_cloudwatch_logs ? local.cloudwatch_logs_options : local.firelens_logs_options
      }
      environment = concat(local.main_environment, var.environment_list)
    }
  ]
  firelensContainerDefinition = [
    {
      essential = true
      image     = "906394416424.dkr.ecr.us-east-1.amazonaws.com/aws-for-fluent-bit:latest"
      name      = "log_router"
      firelensConfiguration = {
        type = "fluentbit"
        options = {
          config-file-type  = "file"
          config-file-value = "/fluent-bit/configs/parse-json.conf"
        }
      }
      memoryReservation = 50
    },
    {
      essential = true
      image     = var.ecr_image_url
      name      = var.name
      portMappings = [
        {
          containerPort = var.port
          hostPort      = var.port
        }
      ]
      logConfiguration = {
        logDriver = var.use_cloudwatch_logs ? "awslogs" : "awsfirelens"
        options   = var.use_cloudwatch_logs ? local.cloudwatch_logs_options : local.firelens_logs_options
      }
      environment = concat(local.main_environment, var.environment_list)
    }
  ]
}

// Auxiliary logs
resource "aws_cloudwatch_log_group" "main" {
  count             = var.use_cloudwatch_logs ? 0 : 1
  name              = "${var.name}-firelens-container"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "main_app" {
  count             = var.use_cloudwatch_logs ? 1 : 0
  name              = var.name
  retention_in_days = 14
}

// AWS ELB Target Blue groups/Listener for Blue/Green Deployments
resource "aws_lb_target_group" "blue" {
  name        = "${var.name}-blue"
  port        = 80
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id
}

// AWS ELB Target Green groups/Listener for Blue/Green Deployments
resource "aws_lb_target_group" "green" {
  name        = "${var.name}-green"
  port        = 80
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id
}

// AWS ELB Listener port application to forward network load balancer
resource "aws_lb_listener" "main_blue_green" {
  load_balancer_arn = var.lb_arn
  protocol          = "TCP"
  port              = var.port

  depends_on = [aws_lb_target_group.blue]

  default_action {
    target_group_arn = aws_lb_target_group.blue.arn
    type             = "forward"
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}

// AWS ELB Test Listener port application to test traffic before rerouting
resource "aws_lb_listener" "main_test_blue_green" {
  load_balancer_arn = var.lb_arn
  protocol          = "TCP"
  port              = var.port_test

  depends_on = [aws_lb_target_group.blue]

  default_action {
    target_group_arn = aws_lb_target_group.blue.arn
    type             = "forward"
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}

/*====================================================================
      AWS CodeDeploy integration for Blue/Green Deployments.
====================================================================*/

// AWS Codedeploy apps defintion for each module
resource "aws_codedeploy_app" "main" {
  compute_platform = "ECS"
  name             = "Deployment-${var.name}"
}

// AWS Codedeploy Group for each codedeploy app created
resource "aws_codedeploy_deployment_group" "main" {
  count = 1
  app_name               = aws_codedeploy_app.main.name
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"
  deployment_group_name  = "deployment-group-${var.name}"
  service_role_arn       = var.service_role_codedeploy

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }

    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 0
    }
  }

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  ecs_service {
    cluster_name = var.cluster
    service_name = aws_ecs_service.main[count.index].name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [
          aws_lb_listener.main_blue_green.arn]
      }

      target_group {
        name = aws_lb_target_group.blue.name
      }

      target_group {
        name = aws_lb_target_group.green.name
      }

      test_traffic_route {
        listener_arns = [
          aws_lb_listener.main_test_blue_green.arn]
      }
    }
  }

  trigger_configuration {
    trigger_events = [
      "DeploymentSuccess",
      "DeploymentFailure",
    ]

    trigger_name       = data.external.commit_message.result["message"]
    trigger_target_arn = var.sns_topic_arn
  }

  lifecycle {
    ignore_changes = [blue_green_deployment_config]
  }
}

// Get commit message
data "external" "commit_message" {
  program = [
    "node",
    "-r",
    "ts-node/register",
    "git_message.ts",
  ]

  working_dir = "../scripts"
}

/*===========================================
              Autoscaling zone
============================================*/

// AWS Autoscaling target to linked the ecs cluster and service
resource "aws_appautoscaling_target" "main" {
  count = 1
  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster}/${aws_ecs_service.main[count.index].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  role_arn           = var.auto_scale_role
  min_capacity       = var.min_scale
  max_capacity       = var.max_scale

  lifecycle {
    ignore_changes = [
      role_arn,
    ]
  }
}

// AWS Autoscaling policy to scale using cpu allocation
resource "aws_appautoscaling_policy" "cpu" {
  count = 1
  name               = "ecs_scale_cpu"
  resource_id        = aws_appautoscaling_target.main[count.index].resource_id
  scalable_dimension = aws_appautoscaling_target.main[count.index].scalable_dimension
  service_namespace  = aws_appautoscaling_target.main[count.index].service_namespace
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value       = 75
    scale_in_cooldown  = 60
    scale_out_cooldown = 60
  }

  depends_on = [aws_appautoscaling_target.main]
}

// AWS Autoscaling policy to scale using memory allocation
resource "aws_appautoscaling_policy" "memory" {
  count = 1
  name               = "ecs_scale_memory"
  resource_id        = aws_appautoscaling_target.main[count.index].resource_id
  scalable_dimension = aws_appautoscaling_target.main[count.index].scalable_dimension
  service_namespace  = aws_appautoscaling_target.main[count.index].service_namespace
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }

    target_value       = 75
    scale_in_cooldown  = 60
    scale_out_cooldown = 60
  }

  depends_on = [
    aws_appautoscaling_target.main
  ]
}
