output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "availability_zones" {
  value = local.azs
}

output "ecr_repository_url" {
  description = "Push container images here"
  value       = aws_ecr_repository.app.repository_url
}

output "alb_dns_name" {
  description = "Public URL of the service"
  value       = aws_lb.main.dns_name
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}

output "github_actions_role_arn" {
  description = "Role ARN for the GitHub Actions OIDC trust"
  value       = aws_iam_role.github_actions.arn
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}