from conftest import REGION, run


def _db(rds, name, **kw):
    params = dict(
        DBInstanceIdentifier=name,
        Engine="postgres",
        DBInstanceClass="db.t4g.micro",
        MasterUsername="admin",
        MasterUserPassword="password123",
        AllocatedStorage=20,
        StorageEncrypted=True,
        PubliclyAccessible=False,
        BackupRetentionPeriod=7,
    )
    params.update(kw)
    return rds.create_db_instance(**params)["DBInstance"]["DBInstanceArn"]


def test_rds_checks(aws, ctx):
    rds = aws.client("rds")
    good = _db(rds, "good")
    public = _db(rds, "public", PubliclyAccessible=True)
    plain = _db(rds, "plain", StorageEncrypted=False)
    nobackup = _db(rds, "nobackup", BackupRetentionPeriod=0)

    assert [f.resource for f in run("RDS-001", ctx)] == [public]
    assert [f.resource for f in run("RDS-002", ctx)] == [plain]
    [f] = run("RDS-003", ctx)
    assert f.resource == nobackup and f.severity.name == "HIGH"
    assert good not in {f.resource for c in ("RDS-001", "RDS-002", "RDS-003") for f in run(c, ctx)}


def test_cloudtrail_missing_then_present(aws, ctx):
    assert len(run("CT-001", ctx)) == 1

    aws.client("s3").create_bucket(Bucket="trail-logs")
    ct = aws.client("cloudtrail")
    ct.create_trail(Name="org", S3BucketName="trail-logs", IsMultiRegionTrail=True)
    assert len(run("CT-001", ctx)) == 1  # created but not logging yet
    ct.start_logging(Name="org")
    assert run("CT-001", ctx) == []


def test_unattached_volume_cost(aws, ctx):
    ec2 = aws.client("ec2")
    vol = ec2.create_volume(AvailabilityZone=f"{REGION}a", Size=100, VolumeType="gp3")["VolumeId"]
    [f] = run("COST-001", ctx)
    assert f.resource == vol and f.category == "cost"
    assert f.monthly_cost_usd == 8.0


def test_idle_elastic_ip(aws, ctx):
    ec2 = aws.client("ec2")
    alloc = ec2.allocate_address(Domain="vpc")["AllocationId"]
    [f] = run("COST-002", ctx)
    assert f.resource == alloc and f.monthly_cost_usd == 3.65


def test_old_snapshots(aws, ctx, future_ctx):
    ec2 = aws.client("ec2")
    vol = ec2.create_volume(AvailabilityZone=f"{REGION}a", Size=50)["VolumeId"]
    snap = ec2.create_snapshot(VolumeId=vol)["SnapshotId"]
    assert run("COST-003", ctx) == []
    # moto pre-creates AMI-backing snapshots in the mock account, so check membership.
    assert snap in {f.resource for f in run("COST-003", future_ctx)}
