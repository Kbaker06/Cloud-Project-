variable "name" {
  type    = string
  default = "orders"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "processor_max_concurrency" {
  description = "Cap on concurrent processor invocations from SQS — protects downstreams from a backlog stampede."
  type        = number
  default     = 5

  validation {
    condition     = var.processor_max_concurrency >= 2
    error_message = "SQS event source maximum_concurrency must be >= 2."
  }
}

variable "max_receive_count" {
  description = "Deliveries before a message is moved to the DLQ."
  type        = number
  default     = 3
}

variable "high_value_threshold" {
  type    = number
  default = 1000
}

variable "alert_email" {
  type    = string
  default = null
}

variable "api_throttle_rps" {
  type    = number
  default = 50
}
