output "ecs_service_id" {
  description = "ID of service created"
  value       = join("", aws_ecs_service.main[*].id)
}

output "ecs_task_arn" {
  description = "ARN of ecs task"
  value       = var.use_cloudwatch_logs ? join("", aws_ecs_task_definition.main_cloudwatch[*].arn) : join("" ,aws_ecs_task_definition.main_elasticsearch_logs[*].arn)
}

output "codedeploy_group_id" {
  description = "Codedeploy group id"
  value       = join("", aws_codedeploy_deployment_group.main[*].id)
}
