output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_name" {
  value = aws_ecs_service.this.name
}

output "security_group_id" {
  description = "Allow this SG into downstream resources (e.g. the database)."
  value       = aws_security_group.service.id
}

output "task_role_arn" {
  value = aws_iam_role.task.arn
}

output "task_role_name" {
  description = "Attach app-specific policies to this role."
  value       = aws_iam_role.task.name
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.this.name
}

output "target_group_arn" {
  value = aws_lb_target_group.this.arn
}
