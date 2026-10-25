import importlib
import os
import sys
from pathlib import Path

import boto3
import pytest
from moto import mock_aws

SRC = Path(__file__).resolve().parents[1] / "src"


@pytest.fixture(autouse=True)
def aws_env(monkeypatch):
    # Never let a test touch a real account, even if the developer has credentials exported.
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    monkeypatch.delenv("AWS_PROFILE", raising=False)


@pytest.fixture
def aws(aws_env, monkeypatch):
    with mock_aws():
        ddb = boto3.client("dynamodb")
        ddb.create_table(
            TableName="orders",
            KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        queue_url = boto3.client("sqs").create_queue(QueueName="orders")["QueueUrl"]
        monkeypatch.setenv("TABLE_NAME", "orders")
        monkeypatch.setenv("QUEUE_URL", queue_url)
        yield {"queue_url": queue_url}


def load(name: str):
    """Import src/<name>/handler.py fresh, inside the active moto mock."""
    path = str(SRC / name)
    sys.path.insert(0, path)
    try:
        sys.modules.pop("handler", None)
        return importlib.import_module("handler")
    finally:
        sys.path.remove(path)


@pytest.fixture
def api(aws):
    return load("api")


@pytest.fixture
def processor(aws):
    return load("processor")
