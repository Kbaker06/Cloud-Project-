"""SQS consumer: persist orders idempotently.

Key behaviours:
  * Partial batch failure: only the failed messages go back to the queue, not the whole batch.
  * Idempotency: a conditional put means SQS at-least-once delivery never creates duplicates.
  * Poison messages: malformed bodies are retried maxReceiveCount times, then land in the DLQ.

Notice what this function does NOT do: publish the OrderAccepted event. Doing "write to the DB, then
publish" here is a dual write — if the publish fails, the retry sees the row already exists and the
event is lost forever. Instead the DynamoDB stream *is* the outbox: an EventBridge Pipe turns every
INSERT into an event (see terraform/events.tf), so the event exists if and only if the row does.
"""

from __future__ import annotations

import json
import logging
import os
import time
from decimal import Decimal
from typing import Any

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

_ddb = boto3.resource("dynamodb")

TABLE_NAME = os.environ.get("TABLE_NAME", "")
RETENTION_DAYS = int(os.environ.get("ORDER_RETENTION_DAYS", "90"))
HIGH_VALUE_THRESHOLD = Decimal(os.environ.get("HIGH_VALUE_THRESHOLD", "1000"))


class PermanentError(Exception):
    """The message can never succeed. Retrying only delays it reaching the DLQ."""


def _log(msg: str, **fields: Any) -> None:
    logger.info(json.dumps({"msg": msg, **fields}, default=str))


def parse(record: dict[str, Any]) -> dict[str, Any]:
    try:
        body = json.loads(record["body"], parse_float=Decimal)
    except (KeyError, json.JSONDecodeError) as e:
        raise PermanentError(f"unparseable body: {e}") from None
    if not isinstance(body, dict):
        raise PermanentError("body is not an object")
    for field in ("order_id", "customer_id", "items", "total"):
        if field not in body:
            raise PermanentError(f"missing field {field}")
    return body


def persist(order: dict[str, Any]) -> bool:
    """Write the order once. Returns False if it already existed (duplicate delivery)."""
    now = int(time.time())
    total = Decimal(str(order["total"]))
    try:
        _ddb.Table(TABLE_NAME).put_item(
            Item={
                "pk": f"ORDER#{order['order_id']}",
                "order_id": order["order_id"],
                "customer_id": order["customer_id"],
                "items": order["items"],
                "total": total,
                # Pre-computed so EventBridge rules can route on it (stream numbers arrive as strings).
                "tier": "HIGH_VALUE" if total >= HIGH_VALUE_THRESHOLD else "STANDARD",
                "status": "CONFIRMED",
                "created_at": now,
                "expires_at": now + RETENTION_DAYS * 86400,  # DynamoDB TTL attribute
            },
            ConditionExpression="attribute_not_exists(pk)",
        )
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    failures = []
    for record in event.get("Records", []):
        message_id = record.get("messageId")
        try:
            order = parse(record)
            if persist(order):
                _log("order confirmed", order_id=order["order_id"], total=order["total"])
            else:
                _log("duplicate delivery ignored", order_id=order["order_id"])
        except PermanentError as e:
            _log("poison message", message_id=message_id, error=str(e))
            failures.append({"itemIdentifier": message_id})
        except Exception:
            logger.exception("transient failure for %s", message_id)
            failures.append({"itemIdentifier": message_id})

    # Requires function_response_types = ["ReportBatchItemFailures"] on the event source mapping.
    return {"batchItemFailures": failures}
