from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor, as_completed

from botocore.exceptions import BotoCoreError, ClientError

from .models import CheckError, Finding, ScanResult
from .registry import Check, Context


def enabled_regions(ctx: Context) -> list[str]:
    ec2 = ctx.client("ec2", ctx.session.region_name or "us-east-1")
    return sorted(r["RegionName"] for r in ec2.describe_regions(AllRegions=False)["Regions"])


def _run_one(ctx: Context, chk: Check, region: str) -> tuple[list[Finding], CheckError | None]:
    try:
        return list(chk.fn(ctx, region)), None
    except (ClientError, BotoCoreError) as e:
        # A missing permission must not hide every other finding — record it and keep going.
        return [], CheckError(chk.id, region, str(e))


def scan(
    ctx: Context, checks: list[Check], regions: list[str], baseline: set[str] | None = None, workers: int = 16
) -> ScanResult:
    result = ScanResult(account_id=ctx.account_id(), regions=regions)
    jobs = [(c, "global") for c in checks if c.global_] + [(c, r) for c in checks if not c.global_ for r in regions]

    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(_run_one, ctx, c, r) for c, r in jobs]
        for fut in as_completed(futures):
            findings, err = fut.result()
            if err:
                result.errors.append(err)
            for f in findings:
                if baseline and f.fingerprint in baseline:
                    result.suppressed += 1
                else:
                    result.findings.append(f)
    return result
