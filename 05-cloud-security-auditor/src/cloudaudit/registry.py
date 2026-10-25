"""Check registry. A check is a function (ctx, region) -> Iterable[Finding], registered by decorator."""

from __future__ import annotations

import fnmatch
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from datetime import datetime, timezone

import boto3

from .models import Finding


@dataclass(frozen=True)
class Check:
    id: str
    service: str
    title: str
    global_: bool  # IAM, S3 bucket listing etc. are global: run once, not per region
    fn: Callable[[Context, str], Iterable[Finding]]


_REGISTRY: dict[str, Check] = {}


def check(id: str, service: str, title: str, global_: bool = False):
    def deco(fn):
        if id in _REGISTRY:
            raise ValueError(f"duplicate check id {id}")
        _REGISTRY[id] = Check(id, service, title, global_, fn)
        return fn

    return deco


def all_checks() -> list[Check]:
    from . import checks  # noqa: F401  (importing registers every check)

    return sorted(_REGISTRY.values(), key=lambda c: c.id)


def select(patterns: list[str] | None) -> list[Check]:
    checks = all_checks()
    if not patterns:
        return checks
    chosen = [c for c in checks if any(fnmatch.fnmatch(c.id, p.upper()) for p in patterns)]
    if not chosen:
        raise ValueError(f"no checks match {patterns}")
    return chosen


class Context:
    """Holds the boto3 session and caches clients per (service, region). `now` is injectable for tests."""

    def __init__(self, session: boto3.Session | None = None, now: datetime | None = None):
        self.session = session or boto3.Session()
        self.now = now or datetime.now(timezone.utc)
        self._clients: dict[tuple[str, str], object] = {}

    def client(self, service: str, region: str):
        key = (service, region)
        if key not in self._clients:
            self._clients[key] = self.session.client(service, region_name=region)
        return self._clients[key]

    def account_id(self) -> str:
        return self.client("sts", self.session.region_name or "us-east-1").get_caller_identity()["Account"]
