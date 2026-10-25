variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "alb_security_group_id" {
  type = string
}

variable "alb_listener_arn" {
  type = string
}

variable "alb_arn_suffix" {
  type = string
}

variable "listener_rule_priority" {
  type    = number
  default = 100
}

variable "path_patterns" {
  type    = list(string)
  default = ["/*"]
}

variable "image" {
  description = "Full container image reference. Pin a digest or immutable tag in prod — never :latest."
  type        = string
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "health_check_path" {
  type    = string
  default = "/healthz"
}

variable "cpu" {
  description = "Fargate task CPU units (256 = 0.25 vCPU)."
  type        = number
  default     = 256
}

variable "memory" {
  description = "Fargate task memory (MiB)."
  type        = number
  default     = 512
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "min_count" {
  type    = number
  default = 2
}

variable "max_count" {
  type    = number
  default = 6

  validation {
    condition     = var.max_count >= 1
    error_message = "max_count must be at least 1."
  }
}

variable "cpu_target_percent" {
  type    = number
  default = 60
}

variable "requests_per_target" {
  description = "Scale out when each task handles more than this many requests/minute."
  type        = number
  default     = 1000
}

variable "use_fargate_spot" {
  description = "Run a share of tasks on FARGATE_SPOT (~70% cheaper, can be interrupted)."
  type        = bool
  default     = false
}

variable "environment" {
  description = "Plain-text environment variables."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Env var name -> Secrets Manager / SSM ARN. Injected at task start, never in plain text."
  type        = map(string)
  default     = {}
}

variable "egress_ports_in_vpc" {
  description = "TCP ports the tasks may reach inside the VPC (e.g. 5432 for Postgres)."
  type        = list(number)
  default     = [5432]
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "enable_alarms" {
  description = "Separate flag (not `topic != null`) because the topic ARN is unknown until apply, and count must be known at plan."
  type        = bool
  default     = false
}

variable "alarm_sns_topic_arn" {
  description = "Where CloudWatch alarms go. Required when enable_alarms = true."
  type        = string
  default     = null
}

variable "enable_execute_command" {
  description = "Allow `aws ecs execute-command` shell access (audited via CloudTrail)."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
