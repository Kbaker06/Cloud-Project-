import json

from conftest import run

ADMIN = json.dumps({"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": "*", "Resource": "*"}]})
SCOPED = json.dumps({"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": "s3:GetObject", "Resource": "*"}]})


def test_console_user_without_mfa(aws, ctx):
    iam = aws.client("iam")
    iam.create_user(UserName="alice")
    iam.create_login_profile(UserName="alice", Password="Sup3r-secret-pw!")
    iam.create_user(UserName="ci-bot")  # no console password: not applicable
    [f] = run("IAM-003", ctx)
    assert f.resource.endswith("user/alice")


def test_stale_access_keys(aws, ctx, future_ctx):
    iam = aws.client("iam")
    iam.create_user(UserName="bob")
    key = iam.create_access_key(UserName="bob")["AccessKey"]["AccessKeyId"]
    assert run("IAM-004", ctx) == []  # brand new key
    [f] = run("IAM-004", future_ctx)  # same key, 400 days later
    assert f.resource.endswith(key)

    iam.update_access_key(UserName="bob", AccessKeyId=key, Status="Inactive")
    assert run("IAM-004", future_ctx) == []


def test_admin_policy_attached(aws, ctx):
    iam = aws.client("iam")
    iam.create_user(UserName="carol")
    admin = iam.create_policy(PolicyName="god-mode", PolicyDocument=ADMIN)["Policy"]["Arn"]
    scoped = iam.create_policy(PolicyName="reader", PolicyDocument=SCOPED)["Policy"]["Arn"]
    iam.create_policy(PolicyName="unattached-admin", PolicyDocument=ADMIN)
    iam.attach_user_policy(UserName="carol", PolicyArn=admin)
    iam.attach_user_policy(UserName="carol", PolicyArn=scoped)
    assert [f.resource for f in run("IAM-005", ctx)] == [admin]


def test_password_policy(aws, ctx):
    iam = aws.client("iam")
    [f] = run("IAM-006", ctx)
    assert "no password policy" in f.detail
    iam.update_account_password_policy(MinimumPasswordLength=8)
    [f] = run("IAM-006", ctx)
    assert "8 < 14" in f.detail and "reuse" in f.detail
    iam.update_account_password_policy(MinimumPasswordLength=16, PasswordReusePrevention=24)
    assert run("IAM-006", ctx) == []


def test_root_checks_run(aws, ctx):
    # moto reports root MFA as disabled by default; the check must notice.
    assert [f.check_id for f in run("IAM-002", ctx)] == ["IAM-002"]
    assert run("IAM-001", ctx) == []
