import json

import boto3
import pytest

GOOD_ORDER = {
    "customer_id": "cust-42",
    "items": [{"sku": "WIDGET", "qty": 3, "unit_price": 19.99}, {"sku": "GADGET", "qty": 1, "unit_price": "5.00"}],
}


def post(api, body, key="order-attempt-1"):
    headers = {"Idempotency-Key": key} if key else {}
    return api.handler(
        {"routeKey": "POST /orders", "headers": headers, "body": json.dumps(body) if not isinstance(body, str) else body},
        None,
    )


def queued_messages(queue_url):
    resp = boto3.client("sqs").receive_message(QueueUrl=queue_url, MaxNumberOfMessages=10)
    return [json.loads(m["Body"]) for m in resp.get("Messages", [])]


def test_accepts_valid_order_and_enqueues(api, aws):
    resp = post(api, GOOD_ORDER)
    assert resp["statusCode"] == 202
    body = json.loads(resp["body"])
    assert resp["headers"]["Location"] == f"/orders/{body['order_id']}"

    [msg] = queued_messages(aws["queue_url"])
    assert msg["order_id"] == body["order_id"]
    assert msg["total"] == "64.97"  # exact decimal arithmetic: 3*19.99 + 5.00


def test_same_idempotency_key_gives_same_order_id(api):
    a = json.loads(post(api, GOOD_ORDER, key="retry-key-1")["body"])["order_id"]
    b = json.loads(post(api, GOOD_ORDER, key="retry-key-1")["body"])["order_id"]
    c = json.loads(post(api, GOOD_ORDER, key="other-key-2")["body"])["order_id"]
    assert a == b != c


@pytest.mark.parametrize("key", [None, "short", "has spaces in it", "x" * 65])
def test_rejects_bad_idempotency_key(api, key):
    assert post(api, GOOD_ORDER, key=key)["statusCode"] == 400


@pytest.mark.parametrize(
    "body",
    [
        "not json",
        [],
        {"items": GOOD_ORDER["items"]},
        {"customer_id": "c", "items": []},
        {"customer_id": "c", "items": [{"sku": "A", "qty": 0, "unit_price": 1}]},
        {"customer_id": "c", "items": [{"sku": "A", "qty": True, "unit_price": 1}]},
        {"customer_id": "c", "items": [{"sku": "A", "qty": 1, "unit_price": -1}]},
        {"customer_id": "c", "items": [{"sku": "A", "qty": 1, "unit_price": "1.001"}]},
        {"customer_id": "c", "items": [{"sku": "A", "qty": 1, "unit_price": "NaN"}]},
        {"customer_id": "c", "items": [{"sku": "A", "qty": 1, "unit_price": "abc"}]},
        {"customer_id": "c", "items": [{"sku": "A", "qty": 1, "unit_price": 1}] * 51},
    ],
)
def test_rejects_invalid_orders(api, aws, body):
    assert post(api, body)["statusCode"] == 400
    assert queued_messages(aws["queue_url"]) == []


def test_get_unknown_order_is_404(api):
    resp = api.handler({"routeKey": "GET /orders/{id}", "pathParameters": {"id": "6f1c1c55-8f0a-4bd4-9d0c-6b4d8f1c2a11"}}, None)
    assert resp["statusCode"] == 404


def test_get_rejects_non_uuid(api):
    resp = api.handler({"routeKey": "GET /orders/{id}", "pathParameters": {"id": "../../etc"}}, None)
    assert resp["statusCode"] == 400


def test_unknown_route(api):
    assert api.handler({"routeKey": "DELETE /orders"}, None)["statusCode"] == 404
