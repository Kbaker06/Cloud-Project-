from __future__ import annotations

import json
import urllib.parse

from botocore.exceptions import ClientError

from ..models import Finding, Severity
from ..registry import Context, check

GLOBAL = "global"
MAX_KEY_AGE_DAYS = 90


def _iam(ctx: Context):
    return ctx.client("iam", "us-east-1")


def _users(ctx: Context):
    for page in _iam(ctx).get_paginator("list_users").paginate():
        yield from page["Users"]


@check("IAM-001", "iam", "Root account has access keys", global_=True)
def root_access_keys(ctx: Context, _region: str):
    summary = _iam(ctx).get_account_summary()["SummaryMap"]
    if summary.get("AccountAccessKeysPresent", 0):
        yield Finding(
            "IAM-001",
            "Root account has access keys",
            Severity.CRITICAL,
            "root",
            GLOBAL,
            "Root access keys cannot be scoped down by any policy and bypass SCP-less guardrails.",
            "Sign in as root → Security credentials → delete the access keys. Use IAM Identity Center for humans.",
        )


@check("IAM-002", "iam", "Root account has no MFA", global_=True)
def root_mfa(ctx: Context, _region: str):
    if not _iam(ctx).get_account_summary()["SummaryMap"].get("AccountMFAEnabled", 0):
        yield Finding(
            "IAM-002",
            "Root account has no MFA",
            Severity.CRITICAL,
            "root",
            GLOBAL,
            "Anyone with the root password owns the account.",
            "Enable a hardware or passkey MFA device on the root user today.",
        )


@check("IAM-003", "iam", "Console user without MFA", global_=True)
def users_without_mfa(ctx: Context, _region: str):
    iam = _iam(ctx)
    for user in _users(ctx):
        try:
            iam.get_login_profile(UserName=user["UserName"])
        except ClientError as e:
            if e.response["Error"]["Code"] == "NoSuchEntity":
                continue  # no console password, MFA not applicable
            raise
        if not iam.list_mfa_devices(UserName=user["UserName"])["MFADevices"]:
            yield Finding(
                "IAM-003",
                "Console user without MFA",
                Severity.HIGH,
                user["Arn"],
                GLOBAL,
                f"{user['UserName']} can sign in to the console with only a password.",
                "Enforce MFA (or move humans to IAM Identity Center and delete the IAM user).",
            )


@check("IAM-004", "iam", f"Active access key older than {MAX_KEY_AGE_DAYS} days", global_=True)
def stale_access_keys(ctx: Context, _region: str):
    iam = _iam(ctx)
    for user in _users(ctx):
        for key in iam.list_access_keys(UserName=user["UserName"])["AccessKeyMetadata"]:
            if key["Status"] != "Active":
                continue
            age = (ctx.now - key["CreateDate"]).days
            if age > MAX_KEY_AGE_DAYS:
                yield Finding(
                    "IAM-004",
                    f"Active access key older than {MAX_KEY_AGE_DAYS} days",
                    Severity.MEDIUM,
                    f"{user['Arn']}/{key['AccessKeyId']}",
                    GLOBAL,
                    f"Key is {age} days old. Long-lived keys are the #1 source of leaked AWS credentials.",
                    "Rotate it — better, replace it with a role (OIDC for CI, instance/task roles for workloads).",
                )


def _statements(doc) -> list[dict]:
    if isinstance(doc, str):
        doc = json.loads(urllib.parse.unquote(doc))
    stmts = doc.get("Statement", [])
    return stmts if isinstance(stmts, list) else [stmts]


def _is_admin(stmt: dict) -> bool:
    actions = stmt.get("Action", [])
    resources = stmt.get("Resource", [])
    actions = actions if isinstance(actions, list) else [actions]
    resources = resources if isinstance(resources, list) else [resources]
    return stmt.get("Effect") == "Allow" and "*" in actions and "*" in resources


@check("IAM-005", "iam", "Customer-managed policy grants full admin (*:*)", global_=True)
def admin_policies(ctx: Context, _region: str):
    iam = _iam(ctx)
    for page in iam.get_paginator("list_policies").paginate(Scope="Local", OnlyAttached=True):
        for pol in page["Policies"]:
            doc = iam.get_policy_version(PolicyArn=pol["Arn"], VersionId=pol["DefaultVersionId"])["PolicyVersion"]["Document"]
            if any(_is_admin(s) for s in _statements(doc)):
                yield Finding(
                    "IAM-005",
                    "Customer-managed policy grants full admin (*:*)",
                    Severity.HIGH,
                    pol["Arn"],
                    GLOBAL,
                    f"{pol['PolicyName']} allows Action '*' on Resource '*' and is attached to "
                    f"{pol.get('AttachmentCount', '?')} principal(s).",
                    "Replace with least-privilege policies. Use IAM Access Analyzer policy generation from CloudTrail activity.",
                )


@check("IAM-006", "iam", "Weak or missing account password policy", global_=True)
def password_policy(ctx: Context, _region: str):
    try:
        policy = _iam(ctx).get_account_password_policy()["PasswordPolicy"]
    except ClientError as e:
        if e.response["Error"]["Code"] != "NoSuchEntity":
            raise
        policy = None
    problems = []
    if policy is None:
        problems.append("no password policy set")
    else:
        if policy.get("MinimumPasswordLength", 0) < 14:
            problems.append(f"minimum length {policy.get('MinimumPasswordLength')} < 14")
        if not policy.get("PasswordReusePrevention"):
            problems.append("password reuse allowed")
    if problems:
        yield Finding(
            "IAM-006",
            "Weak or missing account password policy",
            Severity.LOW,
            "account-password-policy",
            GLOBAL,
            "; ".join(problems),
            "aws iam update-account-password-policy --minimum-password-length 14 --password-reuse-prevention 24 "
            "--require-symbols --require-numbers --require-uppercase-characters --require-lowercase-characters",
        )
