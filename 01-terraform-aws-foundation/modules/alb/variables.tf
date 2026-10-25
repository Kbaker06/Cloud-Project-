variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "certificate_arn" {
  description = "ACM certificate for the HTTPS listener. Null = HTTP only (dev / no domain yet)."
  type        = string
  default     = null
}

variable "ingress_cidrs" {
  description = "Who can reach the load balancer."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "access_logs_bucket" {
  description = "Existing S3 bucket for ALB access logs. Null disables access logging."
  type        = string
  default     = null
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
