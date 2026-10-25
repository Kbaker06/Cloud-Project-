variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "database_subnet_ids" {
  type = list(string)
}

variable "allowed_security_groups" {
  description = <<-EOT
    Security groups allowed to connect on the Postgres port, keyed by a static name
    (e.g. { app = module.app.security_group_id }). A map — not a list — because the
    IDs are unknown until apply and for_each keys must be known at plan time.
  EOT
  type        = map(string)
}

variable "engine_version" {
  type    = string
  default = "16.4"
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling (GiB). Set equal to allocated_storage to disable."
  type        = number
  default     = 100
}

variable "database_name" {
  type    = string
  default = "app"
}

variable "master_username" {
  type    = string
  default = "app_admin"
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "skip_final_snapshot" {
  type    = bool
  default = false
}

variable "performance_insights" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
