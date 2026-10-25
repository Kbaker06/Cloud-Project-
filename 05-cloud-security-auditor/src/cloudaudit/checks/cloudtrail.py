from __future__ import annotations

from ..models import Finding, Severity
from ..registry import Context, check


@check("CT-001", "cloudtrail", "No multi-region CloudTrail trail is logging", global_=True)
def multi_region_trail(ctx: Context, _region: str):
    region = ctx.session.region_name or "us-east-1"
    ct = ctx.client("cloudtrail", region)
    for trail in ct.describe_trails(includeShadowTrails=True)["trailList"]:
        if trail.get("IsMultiRegionTrail") and ct.get_trail_status(Name=trail["TrailARN"]).get("IsLogging"):
            return
    yield Finding(
        "CT-001", "No multi-region CloudTrail trail is logging", Severity.HIGH, "cloudtrail", "global",
        "Without an org/multi-region trail, API activity in unused regions (where attackers mine crypto) goes unrecorded "
        "beyond the 90-day event history.",
        "Create a multi-region trail with log file validation to a locked-down S3 bucket (ideally an org trail).",
    )
