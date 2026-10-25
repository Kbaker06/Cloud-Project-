"""API -> SQS -> processor -> DynamoDB -> API, all against moto."""

import json

import boto3

from conftest import load


def drain_queue_into(processor, queue_url):
    sqs = boto3.client("sqs")
    msgs = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=10)["Messages"]
    result = processor.handler({"Records": [{"messageId": m["MessageId"], "body": m["Body"]} for m in msgs]}, None)
    for m in msgs:
        if m["MessageId"] not in {f["itemIdentifier"] for f in result["batchItemFailures"]}:
            sqs.delete_message(QueueUrl=queue_url, ReceiptHandle=m["ReceiptHandle"])
    return result


def test_order_lifecycle(aws):
    api = load("api")
    order = {"customer_id": "c-1", "items": [{"sku": "A", "qty": 2, "unit_price": "600.00"}]}
    event = {"routeKey": "POST /orders", "headers": {"idempotency-key": "e2e-key-0001"}, "body": json.dumps(order)}

    # Client retries the POST twice (e.g. a timeout on their side).
    ids = {json.loads(api.handler(event, None)["body"])["order_id"] for _ in range(3)}
    assert len(ids) == 1
    order_id = ids.pop()

    get = {"routeKey": "GET /orders/{id}", "pathParameters": {"id": order_id}}
    assert api.handler(get, None)["statusCode"] == 404  # accepted but not processed yet

    processor = load("processor")
    assert drain_queue_into(processor, aws["queue_url"]) == {"batchItemFailures": []}

    resp = api.handler(get, None)
    assert resp["statusCode"] == 200
    body = json.loads(resp["body"])
    assert body["status"] == "CONFIRMED"
    assert body["tier"] == "HIGH_VALUE"
    assert float(body["total"]) == 1200.0

    # Exactly one row despite three deliveries.
    assert boto3.client("dynamodb").scan(TableName="orders")["Count"] == 1
