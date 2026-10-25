from datetime import datetime, timedelta, timezone

import boto3
import pytest
from moto import mock_aws

from cloudaudit.registry import Context

REGION = "us-east-1"


@pytest.fixture(autouse=True)
def aws_env(monkeypatch):
    for k, v in {
        "AWS_ACCESS_KEY_ID": "testing",
        "AWS_SECRET_ACCESS_KEY": "testing",
        "AWS_SESSION_TOKEN": "testing",
        "AWS_DEFAULT_REGION": REGION,
    }.items():
        monkeypatch.setenv(k, v)
    monkeypatch.delenv("AWS_PROFILE", raising=False)


@pytest.fixture
def aws():
    with mock_aws():
        yield boto3.Session(region_name=REGION)


@pytest.fixture
def ctx(aws):
    return Context(aws)


@pytest.fixture
def future_ctx(aws):
    """A context whose clock is 400 days ahead, to age keys and snapshots without sleeping."""
    return Context(aws, now=datetime.now(timezone.utc) + timedelta(days=400))


def run(check_id, ctx, region=REGION):
    from cloudaudit.registry import select

    [chk] = select([check_id])
    return list(chk.fn(ctx, region))
