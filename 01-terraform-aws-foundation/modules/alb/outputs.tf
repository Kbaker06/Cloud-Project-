output "arn" {
  value = aws_lb.this.arn
}

output "arn_suffix" {
  description = "Used as the LoadBalancer dimension in CloudWatch metrics."
  value       = aws_lb.this.arn_suffix
}

output "dns_name" {
  value = aws_lb.this.dns_name
}

output "zone_id" {
  value = aws_lb.this.zone_id
}

output "security_group_id" {
  value = aws_security_group.alb.id
}

output "listener_arn" {
  description = "The listener services should attach rules to (HTTPS if enabled, else HTTP)."
  value       = local.https_enabled ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn
}
