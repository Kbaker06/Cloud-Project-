#!/usr/bin/env bash
# Inspect, then move messages from the DLQ back to the source queue once the bug is fixed.
set -euo pipefail
cd "$(dirname "$0")/../terraform"

DLQ_URL=$(terraform output -raw dlq_url)
DLQ_ARN=$(terraform output -raw dlq_arn)

echo "== Messages in DLQ:"
aws sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names ApproximateNumberOfMessages \
  --query 'Attributes.ApproximateNumberOfMessages' --output text

echo "== Peek (visibility 0, so they stay in the queue):"
aws sqs receive-message --queue-url "$DLQ_URL" --max-number-of-messages 5 --visibility-timeout 0 \
  --query 'Messages[].Body' --output json

read -r -p "Redrive all messages back to the source queue? [y/N] " ok
[[ "$ok" == "y" ]] || exit 0

# Without --destination-arn, messages return to the queue they originally came from.
aws sqs start-message-move-task --source-arn "$DLQ_ARN"
echo "Started. Track with: aws sqs list-message-move-tasks --source-arn $DLQ_ARN"
