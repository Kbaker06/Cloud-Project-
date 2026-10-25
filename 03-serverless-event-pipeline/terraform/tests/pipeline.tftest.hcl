# Architecture guardrails, checked against a mocked AWS provider. `command = apply` here applies
# to the mocks only — nothing is created, but values that are unknown at plan time get resolved.
# Run: terraform init && terraform test

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { name = "us-east-1" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:us-east-1:123456789012:mock" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_resource "aws_lambda_function" {
    defaults = {
      arn        = "arn:aws:lambda:us-east-1:123456789012:function:mock"
      invoke_arn = "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:123456789012:function:mock/invocations"
    }
  }
  mock_resource "aws_dynamodb_table" {
    defaults = {
      arn        = "arn:aws:dynamodb:us-east-1:123456789012:table/mock"
      stream_arn = "arn:aws:dynamodb:us-east-1:123456789012:table/mock/stream/2024-01-01T00:00:00.000"
    }
  }
  mock_resource "aws_cloudwatch_event_bus" {
    defaults = { arn = "arn:aws:events:us-east-1:123456789012:event-bus/mock" }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = { arn = "arn:aws:events:us-east-1:123456789012:rule/mock/mock" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:123456789012:mock" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:mock" }
  }
  mock_resource "aws_apigatewayv2_api" {
    defaults = { execution_arn = "arn:aws:execute-api:us-east-1:123456789012:abc123" }
  }
}

run "queue_visibility_outlasts_processor" {
  command = plan

  assert {
    condition     = aws_sqs_queue.orders.visibility_timeout_seconds >= 6 * aws_lambda_function.processor.timeout
    error_message = "Visibility timeout must be >= 6x the Lambda timeout or messages are processed twice concurrently."
  }
}

run "failures_go_to_a_dlq" {
  command = apply

  assert {
    condition     = jsondecode(aws_sqs_queue.orders.redrive_policy).maxReceiveCount == 3
    error_message = "Orders queue must redrive to the DLQ after 3 receives."
  }

  assert {
    condition     = aws_sqs_queue.dlq.message_retention_seconds == 1209600
    error_message = "DLQ should keep messages for the 14-day maximum."
  }
}

run "partial_batch_failures_enabled" {
  command = apply

  assert {
    condition     = contains(aws_lambda_event_source_mapping.orders.function_response_types, "ReportBatchItemFailures")
    error_message = "Without ReportBatchItemFailures one poison message fails the whole batch."
  }

  assert {
    condition     = aws_lambda_event_source_mapping.orders.scaling_config[0].maximum_concurrency == 5
    error_message = "Processor concurrency should be capped."
  }
}

run "least_privilege" {
  command = apply

  assert {
    condition     = !contains(flatten([for s in data.aws_iam_policy_document.api.statement : s.actions]), "dynamodb:PutItem")
    error_message = "The API function must not be able to write orders directly — only the processor does."
  }

  assert {
    condition     = alltrue([for s in data.aws_iam_policy_document.processor.statement : !contains(s.actions, "dynamodb:*")])
    error_message = "No wildcard DynamoDB permissions."
  }
}

run "only_inserts_become_events" {
  command = apply

  assert {
    condition     = jsondecode(aws_pipes_pipe.order_events.source_parameters[0].filter_criteria[0].filter[0].pattern).eventName == ["INSERT"]
    error_message = "The pipe must only publish new orders (not TTL deletes or updates)."
  }
}

run "concurrency_floor_is_enforced" {
  command = plan

  variables {
    processor_max_concurrency = 1
  }

  expect_failures = [var.processor_max_concurrency]
}
