# One role per function, each with only the actions that function performs.

# ---------------------------------------------------------------------------
# API function
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/${var.name}-api"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "api" {
  name_prefix        = "${var.name}-api-"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "api" {
  statement {
    sid       = "Enqueue"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.orders.arn]
  }
  statement {
    sid       = "ReadOrders"
    actions   = ["dynamodb:GetItem"]
    resources = [aws_dynamodb_table.orders.arn]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.api.arn}:*"]
  }
  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "api" {
  role   = aws_iam_role.api.id
  policy = data.aws_iam_policy_document.api.json
}

resource "aws_lambda_function" "api" {
  function_name    = "${var.name}-api"
  role             = aws_iam_role.api.arn
  runtime          = local.runtime
  architectures    = local.arch
  handler          = "handler.handler"
  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256
  memory_size      = 256
  timeout          = 5

  environment {
    variables = {
      QUEUE_URL  = aws_sqs_queue.orders.url
      TABLE_NAME = aws_dynamodb_table.orders.name
    }
  }

  tracing_config {
    mode = "Active"
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.api.name
  }

  depends_on = [aws_iam_role_policy.api]
}

# ---------------------------------------------------------------------------
# Processor function
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "processor" {
  name              = "/aws/lambda/${var.name}-processor"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "processor" {
  name_prefix        = "${var.name}-proc-"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "processor" {
  statement {
    sid       = "Consume"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
    resources = [aws_sqs_queue.orders.arn]
  }
  statement {
    sid       = "WriteOrders"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.orders.arn]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.processor.arn}:*"]
  }
  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "processor" {
  role   = aws_iam_role.processor.id
  policy = data.aws_iam_policy_document.processor.json
}

resource "aws_lambda_function" "processor" {
  function_name    = "${var.name}-processor"
  role             = aws_iam_role.processor.arn
  runtime          = local.runtime
  architectures    = local.arch
  handler          = "handler.handler"
  filename         = data.archive_file.processor.output_path
  source_code_hash = data.archive_file.processor.output_base64sha256
  memory_size      = 256
  timeout          = local.processor_timeout

  environment {
    variables = {
      TABLE_NAME           = aws_dynamodb_table.orders.name
      HIGH_VALUE_THRESHOLD = tostring(var.high_value_threshold)
    }
  }

  tracing_config {
    mode = "Active"
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.processor.name
  }

  depends_on = [aws_iam_role_policy.processor]
}

resource "aws_lambda_event_source_mapping" "orders" {
  event_source_arn                   = aws_sqs_queue.orders.arn
  function_name                      = aws_lambda_function.processor.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 2
  function_response_types            = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = var.processor_max_concurrency
  }
}
