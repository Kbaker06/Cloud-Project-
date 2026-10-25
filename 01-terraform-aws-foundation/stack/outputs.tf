output "url" {
  value = "${var.certificate_arn == null ? "http" : "https"}://${module.alb.dns_name}"
}

output "ecs_cluster" {
  value = module.app.cluster_name
}

output "ecs_service" {
  value = module.app.service_name
}

output "db_endpoint" {
  value = module.db.endpoint
}

output "db_secret_arn" {
  value = module.db.master_user_secret_arn
}

output "nat_public_ips" {
  value = module.network.nat_public_ips
}

output "github_deploy_role_arn" {
  value = try(module.github_deploy_role[0].role_arn, null)
}
