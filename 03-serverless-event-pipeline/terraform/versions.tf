terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.6"
    }
  }

  # Uncomment after running 01-terraform-aws-foundation/bootstrap:
  # backend "s3" {
  #   key = "03-serverless/terraform.tfstate"
  # }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = var.name
      ManagedBy = "terraform"
    }
  }
}
