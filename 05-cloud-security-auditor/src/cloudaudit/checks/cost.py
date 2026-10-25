"""Cost checks. Prices are us-east-1 list prices — good enough to rank waste, not to bill from."""

from __future__ import annotations

from ..models import Finding, Severity
from ..registry import Context, check

EBS_USD_PER_GB_MONTH = {"gp3": 0.08, "gp2": 0.10, "io1": 0.125, "io2": 0.125, "st1": 0.045, "sc1": 0.015, "standard": 0.05}
EIP_USD_PER_HOUR = 0.005
SNAPSHOT_USD_PER_GB_MONTH = 0.05
OLD_SNAPSHOT_DAYS = 180


@check("COST-001", "ec2", "Unattached EBS volume")
def unattached_volumes(ctx: Context, region: str):
    ec2 = ctx.client("ec2", region)
    pages = ec2.get_paginator("describe_volumes").paginate(Filters=[{"Name": "status", "Values": ["available"]}])
    for page in pages:
        for vol in page["Volumes"]:
            cost = round(vol["Size"] * EBS_USD_PER_GB_MONTH.get(vol.get("VolumeType", "gp2"), 0.10), 2)
            yield Finding(
                "COST-001", "Unattached EBS volume", Severity.LOW, vol["VolumeId"], region,
                f"{vol['Size']} GiB {vol.get('VolumeType')} volume attached to nothing (~${cost}/month).",
                f"Snapshot it if you need the data, then: aws ec2 delete-volume --volume-id {vol['VolumeId']} --region {region}",
                category="cost", monthly_cost_usd=cost,
            )


@check("COST-002", "ec2", "Unassociated Elastic IP")
def idle_eips(ctx: Context, region: str):
    for addr in ctx.client("ec2", region).describe_addresses()["Addresses"]:
        if not addr.get("AssociationId"):
            cost = round(EIP_USD_PER_HOUR * 730, 2)
            yield Finding(
                "COST-002", "Unassociated Elastic IP", Severity.LOW, addr.get("AllocationId", addr.get("PublicIp")), region,
                f"{addr.get('PublicIp')} is reserved but unused (~${cost}/month; all public IPv4 is billed since Feb 2024).",
                f"aws ec2 release-address --allocation-id {addr.get('AllocationId')} --region {region}",
                category="cost", monthly_cost_usd=cost,
            )


@check("COST-003", "ec2", f"EBS snapshot older than {OLD_SNAPSHOT_DAYS} days")
def old_snapshots(ctx: Context, region: str):
    ec2 = ctx.client("ec2", region)
    for page in ec2.get_paginator("describe_snapshots").paginate(OwnerIds=["self"]):
        for snap in page["Snapshots"]:
            age = (ctx.now - snap["StartTime"]).days
            if age > OLD_SNAPSHOT_DAYS:
                # Snapshots are incremental, so VolumeSize is an upper bound on the billed size.
                cost = round(snap.get("VolumeSize", 0) * SNAPSHOT_USD_PER_GB_MONTH, 2)
                yield Finding(
                    "COST-003", f"EBS snapshot older than {OLD_SNAPSHOT_DAYS} days", Severity.INFO, snap["SnapshotId"], region,
                    f"{age} days old, up to {snap.get('VolumeSize')} GiB (≤ ${cost}/month).",
                    "Adopt AWS Data Lifecycle Manager or AWS Backup policies instead of manual snapshots.",
                    category="cost", monthly_cost_usd=cost,
                )
