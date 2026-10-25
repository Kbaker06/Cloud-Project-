output "role_arn" {
  description = "Put this in the workflow: aws-actions/configure-aws-credentials role-to-assume."
  value       = aws_iam_role.this.arn
}

output "oidc_provider_arn" {
  value = local.provider_arn
}
