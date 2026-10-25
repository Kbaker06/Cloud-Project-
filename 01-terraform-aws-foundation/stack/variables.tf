variable "project" {
  type = string
}

variable "environment" {
  type = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "vpc_cidr" {
  type = string
}

variable "az_count" {
  type = number
}

variable "nat_gateway_mode" {
  type = string
}

variable "app_image" {
  type = string
}

variable "app_cpu" {
  type = number
}

variable "app_memory" {
  type = number
}

variable "app_min_count" {
  type = number
}

variable "app_max_count" {
  type = number
}

variable "use_fargate_spot" {
  type = bool
}

variable "db_instance_class" {
  type = string
}

variable "db_multi_az" {
  type = bool
}

variable "db_deletion_protection" {
  type = bool
}

variable "certificate_arn" {
  type    = string
  default = null
}

variable "alarm_email" {
  description = "Subscribed to the alarm topic. You must click the confirmation email."
  type        = string
  default     = null
}

variable "github_repository" {
  description = "owner/repo whose main branch may deploy this environment. Null skips the OIDC role."
  type        = string
  default     = null
}

variable "create_github_oidc_provider" {
  type    = bool
  default = true
}
