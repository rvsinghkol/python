output "app_url" {
  value = local.https_enabled ? "https://${aws_lb.app.dns_name}" : "http://${aws_lb.app.dns_name}"
}

output "alb_dns_name" {
  description = "Point your domain (CNAME/alias) here when you have one"
  value       = aws_lb.app.dns_name
}

output "deployed_image" {
  value = "${data.aws_ecr_repository.app.repository_url}:${var.image_tag}"
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.app.arn
}

output "ecs_cluster" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service" {
  value = aws_ecs_service.app.name
}

output "log_group" {
  value = aws_cloudwatch_log_group.app.name
}
