# Run ONCE per AWS account, with local state, before anything else:
#   terraform init && terraform apply -var budget_email=you@example.com
# It creates the remote-state bucket every other stack uses, plus a billing alarm
# so a forgotten NAT gateway can't quietly cost you $100.

terraform {
  required_version = ">= 1.10" # S3-native state locking (use_lockfile) needs 1.10+
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket_prefix" {
  type    = string
  default = "tfstate"
}

variable "monthly_budget_usd" {
  type    = number
  default = 25
}

variable "budget_email" {
  description = "Gets an email at 50%, 80% and 100% (forecasted) of the monthly budget."
  type        = string
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# State bucket
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  # Account ID in the name makes it globally unique without random suffixes.
  bucket = "${var.state_bucket_prefix}-${data.aws_caller_identity.current.account_id}-${var.region}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled" # Your undo button when a state file gets corrupted.
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = 90
      newer_noncurrent_versions = 10
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "state" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# ---------------------------------------------------------------------------
# Cost guardrail
# ---------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  name         = "monthly-total"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = { "50" = "ACTUAL", "80" = "ACTUAL", "100" = "FORECASTED" }
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = tonumber(notification.key)
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value
      subscriber_email_addresses = [var.budget_email]
    }
  }
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "backend_config" {
  description = "Paste into envs/<env>/backend.hcl"
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.state.bucket}"
    region       = "${var.region}"
    use_lockfile = true
    encrypt      = true
  EOT
}
