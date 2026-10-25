from __future__ import annotations

from ..models import Finding, Severity
from ..registry import Context, check

# Ports that should never be open to the whole internet.
SENSITIVE_PORTS = {
    22: "SSH", 3389: "RDP", 3306: "MySQL", 5432: "PostgreSQL", 1433: "MSSQL",
    6379: "Redis", 27017: "MongoDB", 9200: "Elasticsearch", 2375: "Docker API", 23: "Telnet",
}
OPEN_CIDRS = {"0.0.0.0/0", "::/0"}


def _paginate(client, op: str, key: str, **kwargs):
    for page in client.get_paginator(op).paginate(**kwargs):
        yield from page.get(key, [])


def _exposed_ports(perm: dict) -> list[str]:
    proto = perm.get("IpProtocol")
    if proto == "-1":
        return ["ALL TRAFFIC"]
    if proto not in ("tcp", "6"):
        return []
    lo, hi = perm.get("FromPort", 0), perm.get("ToPort", 65535)
    return [f"{port}/{name}" for port, name in sorted(SENSITIVE_PORTS.items()) if lo <= port <= hi]


@check("EC2-001", "ec2", "Security group exposes sensitive ports to the internet")
def open_security_groups(ctx: Context, region: str):
    ec2 = ctx.client("ec2", region)
    for sg in _paginate(ec2, "describe_security_groups", "SecurityGroups"):
        for perm in sg.get("IpPermissions", []):
            cidrs = {r.get("CidrIp") for r in perm.get("IpRanges", [])} | {r.get("CidrIpv6") for r in perm.get("Ipv6Ranges", [])}
            if not cidrs & OPEN_CIDRS:
                continue
            ports = _exposed_ports(perm)
            if ports:
                yield Finding(
                    "EC2-001", "Security group exposes sensitive ports to the internet",
                    Severity.CRITICAL if "ALL TRAFFIC" in ports or "22/SSH" in ports or "3389/RDP" in ports else Severity.HIGH,
                    sg["GroupId"], region,
                    f"{sg.get('GroupName')} allows {', '.join(ports)} from {', '.join(sorted(cidrs & OPEN_CIDRS))}",
                    "Restrict the source to known CIDRs or security groups. For shell access use SSM Session Manager "
                    "and close port 22 entirely.",
                )


@check("EC2-002", "ec2", "EBS volume is not encrypted")
def unencrypted_volumes(ctx: Context, region: str):
    ec2 = ctx.client("ec2", region)
    for vol in _paginate(ec2, "describe_volumes", "Volumes"):
        if not vol.get("Encrypted"):
            yield Finding(
                "EC2-002", "EBS volume is not encrypted", Severity.MEDIUM, vol["VolumeId"], region,
                f"{vol.get('Size')} GiB {vol.get('VolumeType')} volume stored in plaintext.",
                "Snapshot → copy snapshot with encryption → create volume → swap. Then enable EBS encryption by default.",
            )


@check("EC2-003", "ec2", "EBS encryption by default is disabled")
def ebs_default_encryption(ctx: Context, region: str):
    if not ctx.client("ec2", region).get_ebs_encryption_by_default()["EbsEncryptionByDefault"]:
        yield Finding(
            "EC2-003", "EBS encryption by default is disabled", Severity.LOW, f"region/{region}", region,
            "New volumes in this region will be unencrypted unless every launch remembers to ask.",
            f"aws ec2 enable-ebs-encryption-by-default --region {region}",
        )


@check("EC2-004", "ec2", "Instance allows IMDSv1")
def imdsv1(ctx: Context, region: str):
    ec2 = ctx.client("ec2", region)
    for res in _paginate(ec2, "describe_instances", "Reservations"):
        for inst in res.get("Instances", []):
            if inst.get("State", {}).get("Name") == "terminated":
                continue
            if inst.get("MetadataOptions", {}).get("HttpTokens") != "required":
                yield Finding(
                    "EC2-004", "Instance allows IMDSv1", Severity.HIGH, inst["InstanceId"], region,
                    "IMDSv1 lets any SSRF bug in the app read the instance role's credentials (the Capital One breach pattern).",
                    f"aws ec2 modify-instance-metadata-options --instance-id {inst['InstanceId']} --http-tokens required",
                )
