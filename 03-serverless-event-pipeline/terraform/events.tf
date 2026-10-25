# Transactional outbox: DynamoDB stream INSERT -> EventBridge Pipe -> custom bus -> rules.

resource "aws_cloudwatch_event_bus" "orders" {
  name = "${var.name}-events"
}

resource "aws_sqs_queue" "pipe_dlq" {
  name                    = "${var.name}-pipe-dlq"
  sqs_managed_sse_enabled = true
}

resource "aws_iam_role" "pipe" {
  name_prefix = "${var.name}-pipe-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "pipes.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

data "aws_iam_policy_document" "pipe" {
  statement {
    sid       = "ReadStream"
    actions   = ["dynamodb:DescribeStream", "dynamodb:GetRecords", "dynamodb:GetShardIterator", "dynamodb:ListStreams"]
    resources = [aws_dynamodb_table.orders.stream_arn]
  }
  statement {
    sid       = "PutEvents"
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.orders.arn]
  }
  statement {
    sid       = "DeadLetter"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.pipe_dlq.arn]
  }
}

resource "aws_iam_role_policy" "pipe" {
  role   = aws_iam_role.pipe.id
  policy = data.aws_iam_policy_document.pipe.json
}

resource "aws_pipes_pipe" "order_events" {
  name     = "${var.name}-order-events"
  role_arn = aws_iam_role.pipe.arn
  source   = aws_dynamodb_table.orders.stream_arn
  target   = aws_cloudwatch_event_bus.orders.arn

  source_parameters {
    dynamodb_stream_parameters {
      starting_position      = "LATEST"
      batch_size             = 10
      maximum_retry_attempts = 5
      dead_letter_config {
        arn = aws_sqs_queue.pipe_dlq.arn
      }
    }

    # Only new orders become events; TTL deletions and updates are ignored.
    filter_criteria {
      filter {
        pattern = jsonencode({ eventName = ["INSERT"] })
      }
    }
  }

  target_parameters {
    eventbridge_event_bus_parameters {
      source      = "cloudlab.orders"
      detail_type = "OrderAccepted"
    }

    # Reshape the raw stream record into a clean, versioned domain event.
    input_template = <<-EOT
      {
        "version": "1",
        "order_id": <$.dynamodb.NewImage.order_id.S>,
        "customer_id": <$.dynamodb.NewImage.customer_id.S>,
        "total": <$.dynamodb.NewImage.total.N>,
        "tier": <$.dynamodb.NewImage.tier.S>
      }
    EOT
  }

  depends_on = [aws_iam_role_policy.pipe]
}

# ---------------------------------------------------------------------------
# Consumers: route high-value orders to a review topic, archive everything.
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "fraud_review" {
  name              = "${var.name}-fraud-review"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "fraud_review_email" {
  count     = var.alert_email == null ? 0 : 1
  topic_arn = aws_sns_topic.fraud_review.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

data "aws_iam_policy_document" "fraud_review_topic" {
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.fraud_review.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.high_value.arn]
    }
  }
}

resource "aws_sns_topic_policy" "fraud_review" {
  arn    = aws_sns_topic.fraud_review.arn
  policy = data.aws_iam_policy_document.fraud_review_topic.json
}

resource "aws_cloudwatch_event_rule" "high_value" {
  name           = "${var.name}-high-value-orders"
  event_bus_name = aws_cloudwatch_event_bus.orders.name
  event_pattern = jsonencode({
    source        = ["cloudlab.orders"]
    "detail-type" = ["OrderAccepted"]
    detail        = { tier = ["HIGH_VALUE"] }
  })
}

resource "aws_cloudwatch_event_target" "high_value_sns" {
  rule           = aws_cloudwatch_event_rule.high_value.name
  event_bus_name = aws_cloudwatch_event_bus.orders.name
  target_id      = "fraud-review"
  arn            = aws_sns_topic.fraud_review.arn
}

# Replayable history of every event: when you add a new consumer next month, replay last month into it.
resource "aws_cloudwatch_event_archive" "orders" {
  name             = "${var.name}-all-orders"
  event_source_arn = aws_cloudwatch_event_bus.orders.arn
  retention_days   = 30
}
