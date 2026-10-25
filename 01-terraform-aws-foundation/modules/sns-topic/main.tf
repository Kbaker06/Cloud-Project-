# An SNS topic that AWS services can actually publish to.
#
# Gotcha this module exists for: a topic encrypted with the AWS-managed key `alias/aws/sns` silently
# drops messages from CloudWatch Alarms and EventBridge, because that key's policy can't be edited to
# trust those services. The fix is a customer-managed key whose policy allows them.

variable "name" {
  type = string
}

variable "publisher_services" {
  description = "Service principals allowed to publish, e.g. cloudwatch.amazonaws.com, events.amazonaws.com."
  type        = list(string)
}

variable "source_arns" {
  description = "Optional aws:SourceArn allowlist for publishers (confused-deputy protection). Empty = any in this account."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "key" {
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "AllowPublishingServices"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = var.publisher_services
    }
  }
}

resource "aws_kms_key" "this" {
  description             = "SNS topic ${var.name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.key.json
  tags                    = var.tags
}

resource "aws_kms_alias" "this" {
  name          = "alias/sns-${var.name}"
  target_key_id = aws_kms_key.this.key_id
}

resource "aws_sns_topic" "this" {
  name              = var.name
  kms_master_key_id = aws_kms_key.this.arn
  tags              = var.tags
}

data "aws_iam_policy_document" "topic" {
  statement {
    sid       = "AllowServicePublish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.this.arn]
    principals {
      type        = "Service"
      identifiers = var.publisher_services
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    dynamic "condition" {
      for_each = length(var.source_arns) > 0 ? [1] : []
      content {
        test     = "ArnLike"
        variable = "aws:SourceArn"
        values   = var.source_arns
      }
    }
  }
}

resource "aws_sns_topic_policy" "this" {
  arn    = aws_sns_topic.this.arn
  policy = data.aws_iam_policy_document.topic.json
}

output "arn" {
  value = aws_sns_topic.this.arn
}

output "name" {
  value = aws_sns_topic.this.name
}
