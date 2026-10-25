data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  runtime = "python3.12"
  arch    = ["arm64"]

  # Shared by the function and the queue (the queue can't read it off the function without a cycle).
  processor_timeout = 10
}

# ---------------------------------------------------------------------------
# Storage: DynamoDB on-demand, PITR, TTL, stream as the event outbox
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "orders" {
  name         = "${var.name}-orders"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"

  deletion_protection_enabled = false # flip to true for anything real
}

# ---------------------------------------------------------------------------
# Queue + dead-letter queue
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name}-orders-dlq"
  message_retention_seconds = 1209600 # 14 days: the max, so you have time to investigate
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "orders" {
  name                    = "${var.name}-orders"
  sqs_managed_sse_enabled = true
  # Must be >= 6x the consumer timeout, or messages reappear while still being processed.
  visibility_timeout_seconds = local.processor_timeout * 6
  receive_wait_time_seconds  = 20 # long polling: fewer empty receives, lower cost

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.orders.arn]
  })
}

# ---------------------------------------------------------------------------
# Lambda packaging
# ---------------------------------------------------------------------------
data "archive_file" "api" {
  type        = "zip"
  source_file = "${path.module}/../src/api/handler.py"
  output_path = "${path.module}/.build/api.zip"
}

data "archive_file" "processor" {
  type        = "zip"
  source_file = "${path.module}/../src/processor/handler.py"
  output_path = "${path.module}/.build/processor.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}
