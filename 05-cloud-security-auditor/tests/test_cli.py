import json

from cloudaudit.cli import EXIT_FINDINGS, EXIT_OK, EXIT_USAGE, main


def seed(aws):
    ec2 = aws.client("ec2")
    vpc = ec2.create_vpc(CidrBlock="10.0.0.0/16")["Vpc"]["VpcId"]
    sg = ec2.create_security_group(GroupName="ssh", Description="ssh", VpcId=vpc)["GroupId"]
    ec2.authorize_security_group_ingress(
        GroupId=sg, IpPermissions=[{"IpProtocol": "tcp", "FromPort": 22, "ToPort": 22, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}]
    )
    ec2.create_volume(AvailabilityZone="us-east-1a", Size=10)


def test_json_report_and_exit_code(aws, tmp_path):
    seed(aws)
    out = tmp_path / "report.json"
    code = main(["scan", "--checks", "EC2-*,COST-001", "--format", "json", "-o", str(out)])
    assert code == EXIT_FINDINGS  # SSH open to the world is CRITICAL >= default fail-on HIGH

    report = json.loads(out.read_text())
    ids = {f["check_id"] for f in report["findings"]}
    assert {"EC2-001", "EC2-002", "COST-001"} <= ids
    assert report["summary"]["CRITICAL"] >= 1
    assert report["summary"]["wasted_monthly_usd"] > 0
    assert report["findings"][0]["severity"] == "CRITICAL"  # sorted most severe first


def test_fail_on_never(aws, tmp_path):
    seed(aws)
    assert main(["scan", "--checks", "EC2-001", "--fail-on", "never", "-o", str(tmp_path / "r.txt")]) == EXIT_OK


def test_baseline_suppresses_known_findings(aws, tmp_path):
    seed(aws)
    base = tmp_path / "baseline.json"
    assert main(["scan", "--checks", "EC2-*", "--write-baseline", str(base)]) == EXIT_OK

    out = tmp_path / "after.json"
    assert main(["scan", "--checks", "EC2-*", "--baseline", str(base), "--format", "json", "-o", str(out)]) == EXIT_OK
    report = json.loads(out.read_text())
    assert report["findings"] == [] and report["summary"]["suppressed"] >= 2

    # A *new* problem still fails the build.
    aws.client("ec2").create_volume(AvailabilityZone="us-east-1a", Size=5)
    assert main(["scan", "--checks", "EC2-*", "--baseline", str(base), "--fail-on", "medium", "-o", str(out)]) == EXIT_FINDINGS


def test_sarif_is_valid_shape(aws, tmp_path):
    seed(aws)
    out = tmp_path / "r.sarif"
    main(["scan", "--checks", "EC2-001", "--format", "sarif", "-o", str(out)])
    sarif = json.loads(out.read_text())
    assert sarif["version"] == "2.1.0"
    [res] = sarif["runs"][0]["results"]
    assert res["ruleId"] == "EC2-001" and res["level"] == "error"
    assert "EC2-001" in {r["id"] for r in sarif["runs"][0]["tool"]["driver"]["rules"]}


def test_markdown(aws, tmp_path):
    seed(aws)
    out = tmp_path / "r.md"
    main(["scan", "--checks", "EC2-001", "--format", "markdown", "-o", str(out)])
    assert "| CRITICAL | EC2-001 |" in out.read_text()


def test_bad_arguments(aws, capsys):
    assert main(["scan", "--checks", "NOPE-*"]) == EXIT_USAGE
    assert main(["scan", "--fail-on", "catastrophic"]) == EXIT_USAGE


def test_missing_permission_is_reported_not_fatal(aws, monkeypatch, tmp_path):
    from botocore.exceptions import ClientError

    import cloudaudit.checks.rds as rds_checks

    def denied(ctx, region):
        raise ClientError({"Error": {"Code": "AccessDenied", "Message": "nope"}}, "DescribeDBInstances")

    from cloudaudit import registry

    monkeypatch.setitem(registry._REGISTRY, "RDS-001", registry.Check("RDS-001", "rds", "x", False, denied))
    out = tmp_path / "r.json"
    main(["scan", "--checks", "RDS-001,EC2-003", "--format", "json", "-o", str(out), "--fail-on", "never"])
    report = json.loads(out.read_text())
    assert report["errors"][0]["check_id"] == "RDS-001"
    assert [f["check_id"] for f in report["findings"]] == ["EC2-003"]
    assert rds_checks  # imported to make sure the real module is loaded first
