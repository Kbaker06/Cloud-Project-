from __future__ import annotations

import json

from botocore.exceptions import ClientError

from ..models import Finding, Severity
from ..registry import Context, check

GLOBAL = "global"


def _buckets(ctx: Context):
    return ctx.client("s3", "us-east-1").list_buckets().get("Buckets", [])


def _error_code(e: ClientError) -> str:
    return e.response.get("Error", {}).get("Code", "")


@check("S3-001", "s3", "Bucket Block Public Access not fully enabled", global_=True)
def public_access_block(ctx: Context, _region: str):
    s3 = ctx.client("s3", "us-east-1")
    for b in _buckets(ctx):
        name = b["Name"]
        try:
            cfg = s3.get_public_access_block(Bucket=name)["PublicAccessBlockConfiguration"]
            missing = [k for k, v in cfg.items() if not v]
        except ClientError as e:
            if _error_code(e) != "NoSuchPublicAccessBlockConfiguration":
                raise
            missing = ["all four settings"]
        if missing:
            yield Finding(
                "S3-001",
                "Bucket Block Public Access not fully enabled",
                Severity.HIGH,
                f"arn:aws:s3:::{name}",
                GLOBAL,
                f"Disabled: {', '.join(missing)}",
                f"aws s3api put-public-access-block --bucket {name} --public-access-block-configuration "
                "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true",
            )


def _policy(s3, name: str) -> dict | None:
    try:
        return json.loads(s3.get_bucket_policy(Bucket=name)["Policy"])
    except ClientError as e:
        if _error_code(e) == "NoSuchBucketPolicy":
            return None
        raise


def _as_list(v):
    return v if isinstance(v, list) else [v]


@check("S3-002", "s3", "Bucket policy grants access to everyone", global_=True)
def public_policy(ctx: Context, _region: str):
    s3 = ctx.client("s3", "us-east-1")
    for b in _buckets(ctx):
        policy = _policy(s3, b["Name"])
        for stmt in (policy or {}).get("Statement", []):
            principal = stmt.get("Principal")
            is_everyone = principal == "*" or (isinstance(principal, dict) and "*" in _as_list(principal.get("AWS", [])))
            if stmt.get("Effect") == "Allow" and is_everyone and not stmt.get("Condition"):
                yield Finding(
                    "S3-002",
                    "Bucket policy grants access to everyone",
                    Severity.CRITICAL,
                    f"arn:aws:s3:::{b['Name']}",
                    GLOBAL,
                    f"Statement {stmt.get('Sid', '(no Sid)')} allows {stmt.get('Action')} to Principal '*' with no condition",
                    "Remove the statement or scope it with a Condition (aws:SourceVpce, aws:PrincipalOrgID, ...). "
                    "Serve public content through CloudFront with Origin Access Control instead.",
                )
                break


@check("S3-003", "s3", "Bucket policy does not enforce TLS", global_=True)
def tls_only(ctx: Context, _region: str):
    s3 = ctx.client("s3", "us-east-1")
    for b in _buckets(ctx):
        policy = _policy(s3, b["Name"]) or {}
        enforced = any(
            stmt.get("Effect") == "Deny"
            and str(stmt.get("Condition", {}).get("Bool", {}).get("aws:SecureTransport", "")).lower() == "false"
            for stmt in policy.get("Statement", [])
        )
        if not enforced:
            yield Finding(
                "S3-003",
                "Bucket policy does not enforce TLS",
                Severity.LOW,
                f"arn:aws:s3:::{b['Name']}",
                GLOBAL,
                "No Deny statement on aws:SecureTransport=false; plaintext HTTP requests are accepted.",
                "Add a Deny s3:* statement with Condition Bool aws:SecureTransport = false.",
            )


@check("S3-004", "s3", "Bucket versioning disabled", global_=True)
def versioning(ctx: Context, _region: str):
    s3 = ctx.client("s3", "us-east-1")
    for b in _buckets(ctx):
        status = s3.get_bucket_versioning(Bucket=b["Name"]).get("Status")
        if status != "Enabled":
            yield Finding(
                "S3-004",
                "Bucket versioning disabled",
                Severity.MEDIUM,
                f"arn:aws:s3:::{b['Name']}",
                GLOBAL,
                f"Versioning is {status or 'never enabled'}: an overwrite, delete or ransomware encryption is unrecoverable.",
                f"aws s3api put-bucket-versioning --bucket {b['Name']} --versioning-configuration Status=Enabled "
                "(and add a lifecycle rule to expire old versions).",
            )
