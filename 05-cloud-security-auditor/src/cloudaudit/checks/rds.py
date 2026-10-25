from __future__ import annotations

from ..models import Finding, Severity
from ..registry import Context, check


def _instances(ctx: Context, region: str):
    for page in ctx.client("rds", region).get_paginator("describe_db_instances").paginate():
        yield from page["DBInstances"]


@check("RDS-001", "rds", "Database is publicly accessible")
def public_db(ctx: Context, region: str):
    for db in _instances(ctx, region):
        if db.get("PubliclyAccessible"):
            yield Finding(
                "RDS-001", "Database is publicly accessible", Severity.CRITICAL, db["DBInstanceArn"], region,
                f"{db['DBInstanceIdentifier']} has a public endpoint; only its security group stands between it and the internet.",
                f"aws rds modify-db-instance --db-instance-identifier {db['DBInstanceIdentifier']} --no-publicly-accessible "
                "--apply-immediately, and move it to subnets with no internet route.",
            )


@check("RDS-002", "rds", "Database storage is not encrypted")
def unencrypted_db(ctx: Context, region: str):
    for db in _instances(ctx, region):
        if not db.get("StorageEncrypted"):
            yield Finding(
                "RDS-002", "Database storage is not encrypted", Severity.HIGH, db["DBInstanceArn"], region,
                "Encryption can't be turned on in place for an existing instance.",
                "Snapshot → copy snapshot with a KMS key → restore → cut over.",
            )


@check("RDS-003", "rds", "Automated backups disabled or too short")
def backups(ctx: Context, region: str):
    for db in _instances(ctx, region):
        days = db.get("BackupRetentionPeriod", 0)
        if days < 7:
            yield Finding(
                "RDS-003", "Automated backups disabled or too short", Severity.MEDIUM if days else Severity.HIGH,
                db["DBInstanceArn"], region,
                f"Backup retention is {days} day(s); point-in-time recovery {'is impossible' if not days else 'window is short'}.",
                f"aws rds modify-db-instance --db-instance-identifier {db['DBInstanceIdentifier']} --backup-retention-period 7",
            )
