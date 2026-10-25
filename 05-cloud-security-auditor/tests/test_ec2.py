import pytest

from conftest import REGION, run


def _sg(ec2, name, perms):
    vpc = ec2.create_vpc(CidrBlock="10.0.0.0/16")["Vpc"]["VpcId"]
    sg = ec2.create_security_group(GroupName=name, Description=name, VpcId=vpc)["GroupId"]
    ec2.authorize_security_group_ingress(GroupId=sg, IpPermissions=perms)
    return sg


@pytest.mark.parametrize(
    "perm,severity,expect",
    [
        ({"IpProtocol": "tcp", "FromPort": 22, "ToPort": 22, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}, "CRITICAL", "22/SSH"),
        (
            {"IpProtocol": "tcp", "FromPort": 5432, "ToPort": 5432, "Ipv6Ranges": [{"CidrIpv6": "::/0"}]},
            "HIGH",
            "5432/PostgreSQL",
        ),
        ({"IpProtocol": "tcp", "FromPort": 3000, "ToPort": 7000, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}, "CRITICAL", "3389/RDP"),
        ({"IpProtocol": "-1", "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}, "CRITICAL", "ALL TRAFFIC"),
    ],
)
def test_open_security_groups(aws, ctx, perm, severity, expect):
    sg = _sg(aws.client("ec2"), "bad", [perm])
    findings = [f for f in run("EC2-001", ctx) if f.resource == sg]
    assert len(findings) == 1
    assert findings[0].severity.name == severity
    assert expect in findings[0].detail


@pytest.mark.parametrize(
    "perm",
    [
        {"IpProtocol": "tcp", "FromPort": 443, "ToPort": 443, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]},  # public HTTPS is fine
        {"IpProtocol": "tcp", "FromPort": 22, "ToPort": 22, "IpRanges": [{"CidrIp": "10.0.0.0/8"}]},  # private SSH is fine
        {"IpProtocol": "udp", "FromPort": 22, "ToPort": 22, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]},  # not TCP
    ],
)
def test_safe_security_groups(aws, ctx, perm):
    sg = _sg(aws.client("ec2"), "ok", [perm])
    assert [f for f in run("EC2-001", ctx) if f.resource == sg] == []


def test_unencrypted_volume(aws, ctx):
    ec2 = aws.client("ec2")
    plain = ec2.create_volume(AvailabilityZone=f"{REGION}a", Size=10)["VolumeId"]
    ec2.create_volume(AvailabilityZone=f"{REGION}a", Size=10, Encrypted=True)
    assert [f.resource for f in run("EC2-002", ctx)] == [plain]


def test_ebs_default_encryption(aws, ctx):
    assert len(run("EC2-003", ctx)) == 1
    aws.client("ec2").enable_ebs_encryption_by_default()
    assert run("EC2-003", ctx) == []


def test_imdsv1(aws, ctx):
    ec2 = aws.client("ec2")
    ami = ec2.describe_images(Owners=["amazon"])["Images"][0]["ImageId"]
    v1 = ec2.run_instances(ImageId=ami, MinCount=1, MaxCount=1)["Instances"][0]["InstanceId"]
    ec2.run_instances(ImageId=ami, MinCount=1, MaxCount=1, MetadataOptions={"HttpTokens": "required"})
    assert [f.resource for f in run("EC2-004", ctx)] == [v1]
