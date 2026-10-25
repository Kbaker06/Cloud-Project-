import json

import boto3
from botocore.exceptions import ClientError


def record(message_id, body):
    return {"messageId": message_id, "body": body if isinstance(body, str) else json.dumps(body)}


ORDER = {
    "order_id": "6f1c1c55-8f0a-4bd4-9d0c-6b4d8f1c2a11",
    "customer_id": "cust-42",
    "items": [{"sku": "WIDGET", "qty": 3, "unit_price": "19.99"}],
    "total": "59.97",
}


def table():
    return boto3.resource("dynamodb").Table("orders")


def test_persists_order(processor):
    result = processor.handler({"Records": [record("m1", ORDER)]}, None)
    assert result == {"batchItemFailures": []}

    item = table().get_item(Key={"pk": f"ORDER#{ORDER['order_id']}"})["Item"]
    assert item["status"] == "CONFIRMED"
    assert str(item["total"]) == "59.97"
    assert item["tier"] == "STANDARD"
    assert item["expires_at"] > item["created_at"]


def test_high_value_orders_are_tagged(processor):
    big = {**ORDER, "order_id": "big-1", "total": "1000.00"}
    processor.handler({"Records": [record("m1", big)]}, None)
    assert table().get_item(Key={"pk": "ORDER#big-1"})["Item"]["tier"] == "HIGH_VALUE"


def test_duplicate_delivery_is_a_noop(processor):
    processor.handler({"Records": [record("m1", ORDER)]}, None)
    table().update_item(
        Key={"pk": f"ORDER#{ORDER['order_id']}"},
        UpdateExpression="SET #s = :s",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":s": "SHIPPED"},
    )
    # SQS redelivers the same message: must not reset the order back to CONFIRMED.
    result = processor.handler({"Records": [record("m1-redelivered", ORDER)]}, None)
    assert result == {"batchItemFailures": []}
    assert table().get_item(Key={"pk": f"ORDER#{ORDER['order_id']}"})["Item"]["status"] == "SHIPPED"


def test_partial_batch_failure_reports_only_bad_messages(processor):
    good2 = {**ORDER, "order_id": "second"}
    result = processor.handler(
        {
            "Records": [
                record("ok-1", ORDER),
                record("poison-json", "{not json"),
                record("poison-fields", {"order_id": "x"}),
                record("poison-type", "[1, 2]"),
                record("ok-2", good2),
            ]
        },
        None,
    )
    assert sorted(f["itemIdentifier"] for f in result["batchItemFailures"]) == [
        "poison-fields",
        "poison-json",
        "poison-type",
    ]
    assert table().get_item(Key={"pk": "ORDER#second"}).get("Item")


def test_transient_errors_are_retried(processor, monkeypatch):
    class ThrottledTable:
        def put_item(self, **_kwargs):
            raise ClientError({"Error": {"Code": "ProvisionedThroughputExceededException", "Message": "slow down"}}, "PutItem")

    class ThrottledDynamo:
        def Table(self, _name):
            return ThrottledTable()

    monkeypatch.setattr(processor, "_ddb", ThrottledDynamo())
    result = processor.handler({"Records": [record("m1", ORDER)]}, None)
    assert result == {"batchItemFailures": [{"itemIdentifier": "m1"}]}
