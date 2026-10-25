variable "role_name" {
  type = string
}

variable "github_repository" {
  description = "owner/repo allowed to assume the role."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must look like owner/repo."
  }
}

variable "allowed_subjects" {
  description = <<-EOT
    OIDC `sub` claim patterns, relative to the repo. Examples:
      "ref:refs/heads/main"      - pushes to main
      "environment:production"   - jobs bound to the production environment
      "pull_request"             - PR runs (give these a read-only role!)
  EOT
  type        = list(string)
  default     = ["ref:refs/heads/main"]
}

variable "create_oidc_provider" {
  description = "The provider is one-per-account. Set false if it already exists."
  type        = bool
  default     = true
}

variable "managed_policy_arns" {
  type    = list(string)
  default = []
}

variable "inline_policy_json" {
  type    = string
  default = null
}

variable "max_session_duration" {
  type    = number
  default = 3600
}

variable "tags" {
  type    = map(string)
  default = {}
}
