//  AWS ECS Service to run the task definition
resource "aws_ecs_service" "main" {
  name                = var.name
  cluster             = var.cluster
  task_definition     = aws_ecs_task_definition.main.arn
  scheduling_strategy = "REPLICA"
  desired_count       = var.service_count

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
    create_before_destroy = true

    ignore_changes = [
      load_balancer,
      desired_count,
      task_definition,
    ]
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 100
  }

  deployment_controller {
    type = "CODE_DEPLOY"
  }
}

// AWS ECS Task defintion to run the container passed by name
resource "aws_ecs_task_definition" "main" {
  family                   = "${var.name}-service"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  execution_role_arn       = var.roleExecArn
  task_role_arn            = var.roleArn
  cpu                      = var.cpu_unit
  memory                   = var.memory
  container_definitions    = data.template_file.main.rendered

  lifecycle {
    create_before_destroy = true
  }
}

data "template_file" "main" {
  template = file("${path.module}/task_definition.json")

  vars = {
    ecr_image_url      = var.ecr_image_url
    name               = var.name
    name_index_log     = lower(var.name)
    port               = var.port
    region             = var.region
    secrets_name       = var.secrets_name
    secrets_value_arn  = var.secrets_value_arn
    database_log_level = var.database_log_level
    log_level          = var.log_level
    es_url             = var.es_url
  }
}

// AWS ELB Target Blue groups/Listener for Blue/Green Deployments 
resource "aws_lb_target_group" "blue" {
  name        = "${var.name}-blue"
  port        = 80
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  lifecycle {
    create_before_destroy = true
  }
}

// AWS ELB Target Green groups/Listener for Blue/Green Deployments
resource "aws_lb_target_group" "green" {
  name        = "${var.name}-green"
  port        = 80
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  lifecycle {
    create_before_destroy = true
  }
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
    create_before_destroy = true
    ignore_changes        = [default_action]
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
    create_before_destroy = true
    ignore_changes        = [default_action]
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
    service_name = aws_ecs_service.main.name
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
  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster}/${aws_ecs_service.main.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  role_arn           = var.auto_scale_role
  min_capacity       = var.min_scale
  max_capacity       = var.max_scale

  lifecycle {
    create_before_destroy = true

    ignore_changes = [
      role_arn,
    ]
  }
}

// AWS Autoscaling policy to scale using cpu allocation
resource "aws_appautoscaling_policy" "cpu" {
  name               = "ecs_scale_cpu"
  resource_id        = aws_appautoscaling_target.main.resource_id
  scalable_dimension = aws_appautoscaling_target.main.scalable_dimension
  service_namespace  = aws_appautoscaling_target.main.service_namespace
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

  lifecycle {
    create_before_destroy = true
  }
}

// AWS Autoscaling policy to scale using memory allocation
resource "aws_appautoscaling_policy" "memory" {
  name               = "ecs_scale_memory"
  resource_id        = aws_appautoscaling_target.main.resource_id
  scalable_dimension = aws_appautoscaling_target.main.scalable_dimension
  service_namespace  = aws_appautoscaling_target.main.service_namespace
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
  aws_appautoscaling_target.main]

  lifecycle {
    create_before_destroy = true
  }
}
