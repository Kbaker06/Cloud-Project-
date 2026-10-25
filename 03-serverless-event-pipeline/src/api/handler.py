"""HTTP API: POST /orders (accept + enqueue) and GET /orders/{id} (read).

Accepting an order only validates and enqueues it — the slow, failure-prone work happens in the
processor. That's what lets this endpoint stay fast and available even when downstream is broken.
"""

from __future__ import annotations

import json
import logging
import os
import re
import uuid
from decimal import Decimal, InvalidOperation
from typing import Any

import boto3

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

# Created at import time so warm invocations reuse connections.
_sqs = boto3.client("sqs")
_ddb = boto3.resource("dynamodb")

QUEUE_URL = os.environ.get("QUEUE_URL", "")
TABLE_NAME = os.environ.get("TABLE_NAME", "")

IDEMPOTENCY_KEY_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
MAX_ITEMS = 50


class ValidationError(Exception):
    pass


def _response(status: int, body: dict[str, Any], headers: dict[str, str] | None = None) -> dict[str, Any]:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json", **(headers or {})},
        "body": json.dumps(body, default=str),
    }


def validate_order(payload: Any) -> dict[str, Any]:
    """Return a normalised order or raise ValidationError. Money is Decimal, never float."""
    if not isinstance(payload, dict):
        raise ValidationError("body must be a JSON object")

    customer_id = payload.get("customer_id")
    if not isinstance(customer_id, str) or not 1 <= len(customer_id) <= 64:
        raise ValidationError("customer_id must be a string of 1-64 chars")

    items = payload.get("items")
    if not isinstance(items, list) or not 1 <= len(items) <= MAX_ITEMS:
        raise ValidationError(f"items must be a list of 1-{MAX_ITEMS} entries")

    normalised = []
    total = Decimal("0")
    for i, item in enumerate(items):
        if not isinstance(item, dict):
            raise ValidationError(f"items[{i}] must be an object")
        sku = item.get("sku")
        qty = item.get("qty")
        if not isinstance(sku, str) or not sku:
            raise ValidationError(f"items[{i}].sku is required")
        if not isinstance(qty, int) or isinstance(qty, bool) or not 1 <= qty <= 1000:
            raise ValidationError(f"items[{i}].qty must be an integer 1-1000")
        try:
            price = Decimal(str(item.get("unit_price")))
        except (InvalidOperation, ValueError):
            raise ValidationError(f"items[{i}].unit_price must be a number") from None
        if not price.is_finite() or price <= 0 or price.as_tuple().exponent < -2:
            raise ValidationError(f"items[{i}].unit_price must be positive with at most 2 decimals")
        normalised.append({"sku": sku, "qty": qty, "unit_price": str(price)})
        total += price * qty

    return {"customer_id": customer_id, "items": normalised, "total": str(total)}


def create_order(event: dict[str, Any]) -> dict[str, Any]:
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    key = headers.get("idempotency-key", "")
    if not IDEMPOTENCY_KEY_RE.match(key):
        return _response(400, {"error": "Idempotency-Key header required (8-64 chars, [A-Za-z0-9_-])"})

    try:
        order = validate_order(json.loads(event.get("body") or ""))
    except json.JSONDecodeError:
        return _response(400, {"error": "body must be valid JSON"})
    except ValidationError as e:
        return _response(400, {"error": str(e)})

    # The order id is derived from the client's idempotency key, so a retried POST maps to the
    # same order and the processor's conditional write turns the duplicate into a no-op.
    order_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"orders/{order['customer_id']}/{key}"))
    message = {"order_id": order_id, **order}

    _sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps(message),
        MessageAttributes={"schema": {"DataType": "String", "StringValue": "order.v1"}},
    )
    logger.info(json.dumps({"msg": "order accepted", "order_id": order_id, "total": order["total"]}))
    return _response(202, {"order_id": order_id, "status": "ACCEPTED"}, {"Location": f"/orders/{order_id}"})


def get_order(order_id: str) -> dict[str, Any]:
    try:
        uuid.UUID(order_id)
    except ValueError:
        return _response(400, {"error": "invalid order id"})
    item = _ddb.Table(TABLE_NAME).get_item(Key={"pk": f"ORDER#{order_id}"}).get("Item")
    if not item:
        # Not found *yet* is normal right after a 202 — the client should poll.
        return _response(404, {"error": "order not found (it may still be processing)"})
    item.pop("pk", None)
    return _response(200, item)


def handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    route = event.get("routeKey", "")
    try:
        if route == "POST /orders":
            return create_order(event)
        if route == "GET /orders/{id}":
            return get_order((event.get("pathParameters") or {}).get("id", ""))
        return _response(404, {"error": "route not found"})
    except Exception:
        logger.exception("unhandled error")
        return _response(500, {"error": "internal error"})
