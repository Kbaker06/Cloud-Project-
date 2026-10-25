import json

from conftest import run


def test_bucket_without_public_access_block(aws, ctx):
    aws.client("s3").create_bucket(Bucket="leaky")
    [f] = run("S3-001", ctx)
    assert f.resource == "arn:aws:s3:::leaky"
    assert f.severity.name == "HIGH"


def test_fully_blocked_bucket_passes(aws, ctx):
    s3 = aws.client("s3")
    s3.create_bucket(Bucket="locked")
    s3.put_public_access_block(
        Bucket="locked",
        PublicAccessBlockConfiguration={k: True for k in ("BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets")},
    )
    assert run("S3-001", ctx) == []


def test_partially_blocked_bucket_lists_missing_settings(aws, ctx):
    s3 = aws.client("s3")
    s3.create_bucket(Bucket="half")
    s3.put_public_access_block(
        Bucket="half",
        PublicAccessBlockConfiguration={"BlockPublicAcls": True, "IgnorePublicAcls": True, "BlockPublicPolicy": False, "RestrictPublicBuckets": False},
    )
    [f] = run("S3-001", ctx)
    assert "BlockPublicPolicy" in f.detail and "RestrictPublicBuckets" in f.detail


def _policy(bucket, *statements):
    return json.dumps({"Version": "2012-10-17", "Statement": list(statements)})


def test_public_bucket_policy_is_critical(aws, ctx):
    s3 = aws.client("s3")
    s3.create_bucket(Bucket="website")
    s3.put_bucket_policy(
        Bucket="website",
        Policy=_policy("website", {"Sid": "Public", "Effect": "Allow", "Principal": "*", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::website/*"}),
    )
    [f] = run("S3-002", ctx)
    assert f.severity.name == "CRITICAL"
    assert "Public" in f.detail


def test_conditioned_wildcard_principal_is_not_public(aws, ctx):
    s3 = aws.client("s3")
    s3.create_bucket(Bucket="vpce-only")
    s3.put_bucket_policy(
        Bucket="vpce-only",
        Policy=_policy(
            "vpce-only",
            {
                "Effect": "Allow",
                "Principal": {"AWS": "*"},
                "Action": "s3:GetObject",
                "Resource": "arn:aws:s3:::vpce-only/*",
                "Condition": {"StringEquals": {"aws:SourceVpce": "vpce-123"}},
            },
        ),
    )
    assert run("S3-002", ctx) == []


def test_tls_enforcement(aws, ctx):
    s3 = aws.client("s3")
    s3.create_bucket(Bucket="plain")
    s3.create_bucket(Bucket="tls")
    s3.put_bucket_policy(
        Bucket="tls",
        Policy=_policy(
            "tls",
            {
                "Effect": "Deny",
                "Principal": "*",
                "Action": "s3:*",
                "Resource": ["arn:aws:s3:::tls", "arn:aws:s3:::tls/*"],
                "Condition": {"Bool": {"aws:SecureTransport": "false"}},
            },
        ),
    )
    assert [f.resource for f in run("S3-003", ctx)] == ["arn:aws:s3:::plain"]


def test_versioning(aws, ctx):
    s3 = aws.client("s3")
    s3.create_bucket(Bucket="unversioned")
    s3.create_bucket(Bucket="versioned")
    s3.put_bucket_versioning(Bucket="versioned", VersioningConfiguration={"Status": "Enabled"})
    s3.create_bucket(Bucket="suspended")
    s3.put_bucket_versioning(Bucket="suspended", VersioningConfiguration={"Status": "Suspended"})
    assert sorted(f.resource for f in run("S3-004", ctx)) == ["arn:aws:s3:::suspended", "arn:aws:s3:::unversioned"]
