output "api_url" {
  value = aws_apigatewayv2_stage.default.invoke_url
}

output "queue_url" {
  value = aws_sqs_queue.orders.url
}

output "dlq_url" {
  value = aws_sqs_queue.dlq.url
}

output "dlq_arn" {
  value = aws_sqs_queue.dlq.arn
}

output "table_name" {
  value = aws_dynamodb_table.orders.name
}

output "event_bus_name" {
  value = aws_cloudwatch_event_bus.orders.name
}
