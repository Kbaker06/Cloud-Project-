terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  # Partial config: `terraform init -backend-config=backend.hcl` (see backend.hcl.example).
  backend "s3" {
    key = "01-foundation/prod/terraform.tfstate"
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      ManagedBy  = "terraform"
      Repository = "Cloud-Project-"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "alarm_email" {
  type    = string
  default = null
}

variable "github_repository" {
  type    = string
  default = null
}

variable "app_image" {
  type    = string
  default = "ghcr.io/kbaker06/pulse-api:0.1.0"
}

variable "certificate_arn" {
  description = "ACM cert for your domain. Prod refuses to run without HTTPS."
  type        = string
}

# Prod: optimise for resilience. NAT per AZ, 3 AZs, on-demand only, Multi-AZ DB.
module "stack" {
  source = "../../stack"

  project     = "cloudlab"
  environment = "prod"

  vpc_cidr         = "10.20.0.0/16"
  az_count         = 3
  nat_gateway_mode = "per_az"

  app_image        = var.app_image
  app_cpu          = 512
  app_memory       = 1024
  app_min_count    = 3
  app_max_count    = 12
  use_fargate_spot = false

  db_instance_class      = "db.t4g.medium"
  db_multi_az            = true
  db_deletion_protection = true

  certificate_arn = var.certificate_arn
  alarm_email     = var.alarm_email
  # The OIDC provider is per-account; dev already created it if both share an account.
  github_repository           = var.github_repository
  create_github_oidc_provider = false
}

output "stack" {
  value = module.stack
}
