variable "name" {
  description = "Name prefix for every resource in this VPC (e.g. \"acme-dev\")."
  type        = string
}

variable "cidr_block" {
  description = "CIDR for the VPC. A /16 gives room for three tiers across three AZs."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.cidr_block)) && tonumber(split("/", var.cidr_block)[1]) <= 20
    error_message = "cidr_block must be a valid IPv4 CIDR no smaller than /20."
  }
}

variable "az_count" {
  description = "How many availability zones to spread subnets across."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4 (ALB and RDS Multi-AZ need at least 2)."
  }
}

variable "nat_gateway_mode" {
  description = <<-EOT
    "single"  - one NAT gateway shared by all AZs (cheap, AZ failure takes out egress).
    "per_az"  - one NAT gateway per AZ (prod: no cross-AZ dependency).
    "none"    - no NAT; private subnets only reach AWS via VPC endpoints.
  EOT
  type        = string
  default     = "single"

  validation {
    condition     = contains(["single", "per_az", "none"], var.nat_gateway_mode)
    error_message = "nat_gateway_mode must be one of: single, per_az, none."
  }
}

variable "enable_flow_logs" {
  description = "Ship VPC flow logs to CloudWatch Logs."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  type    = number
  default = 30
}

variable "interface_endpoints" {
  description = "Interface VPC endpoints to create (service short names, e.g. \"ecr.api\"). Each costs ~$7/month/AZ."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
