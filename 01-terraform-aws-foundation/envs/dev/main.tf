terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }

  # Partial config: `terraform init -backend-config=backend.hcl` (see backend.hcl.example).
  backend "s3" {
    key = "01-foundation/dev/terraform.tfstate"
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

variable "create_github_oidc_provider" {
  description = "The GitHub OIDC provider is one per account. bootstrap/ creates it when given github_repository; only set true if it didn't."
  type        = bool
  default     = false
}

variable "app_image" {
  type    = string
  default = "ghcr.io/kbaker06/pulse-api:0.1.0"
}

# Dev: optimise for cost. Single NAT, Spot, tiny single-AZ DB you can throw away.
module "stack" {
  source = "../../stack"

  project     = "cloudlab"
  environment = "dev"

  vpc_cidr         = "10.10.0.0/16"
  az_count         = 2
  nat_gateway_mode = "single"

  app_image        = var.app_image
  app_cpu          = 256
  app_memory       = 512
  app_min_count    = 1
  app_max_count    = 3
  use_fargate_spot = true

  db_instance_class      = "db.t4g.micro"
  db_multi_az            = false
  db_deletion_protection = false

  alarm_email                 = var.alarm_email
  github_repository           = var.github_repository
  create_github_oidc_provider = var.create_github_oidc_provider
}

output "stack" {
  value = module.stack
}
