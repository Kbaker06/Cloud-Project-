from __future__ import annotations

import argparse
import json
import sys

import boto3

from . import __version__, report
from .models import Severity
from .registry import Context, all_checks, select
from .scanner import enabled_regions, scan

EXIT_OK, EXIT_FINDINGS, EXIT_USAGE = 0, 2, 64


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="cloudaudit", description=__doc__ or "AWS security & cost auditor")
    p.add_argument("--version", action="version", version=f"cloudaudit {__version__}")
    sub = p.add_subparsers(dest="command", required=True)

    s = sub.add_parser("scan", help="scan the account")
    s.add_argument("--profile", help="AWS profile to use")
    s.add_argument("--regions", help="comma-separated regions, or 'all' (default: the session's region)")
    s.add_argument("--checks", help="comma-separated check IDs or globs, e.g. 'S3-*,EC2-001'")
    s.add_argument("--format", choices=sorted(report.FORMATS), default="table")
    s.add_argument("--output", "-o", help="write the report here instead of stdout")
    s.add_argument("--fail-on", default="high", help="exit 2 if any finding is at or above this severity (or 'never')")
    s.add_argument("--baseline", help="JSON report from a previous run; its findings are suppressed")
    s.add_argument("--write-baseline", help="write all current findings' fingerprints here and exit 0")
    s.add_argument("--no-color", action="store_true")

    sub.add_parser("list-checks", help="print every check")
    return p


def _load_baseline(path: str) -> set[str]:
    with open(path) as fh:
        data = json.load(fh)
    return {f["fingerprint"] for f in data.get("findings", [])} | set(data.get("fingerprints", []))


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    if args.command == "list-checks":
        for c in all_checks():
            print(f"{c.id:<9} {c.service:<11} {'global' if c.global_ else 'regional':<9} {c.title}")
        return EXIT_OK

    try:
        checks = select(args.checks.split(",") if args.checks else None)
        fail_on = None if args.fail_on.lower() == "never" else Severity.parse(args.fail_on)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return EXIT_USAGE

    session = boto3.Session(profile_name=args.profile)
    ctx = Context(session)
    if args.regions == "all":
        regions = enabled_regions(ctx)
    elif args.regions:
        regions = [r.strip() for r in args.regions.split(",") if r.strip()]
    else:
        regions = [session.region_name or "us-east-1"]

    baseline = _load_baseline(args.baseline) if args.baseline else None
    result = scan(ctx, checks, regions, baseline)

    if args.write_baseline:
        with open(args.write_baseline, "w") as fh:
            json.dump({"fingerprints": sorted(f.fingerprint for f in result.findings)}, fh, indent=2)
        print(f"baseline of {len(result.findings)} findings written to {args.write_baseline}", file=sys.stderr)
        return EXIT_OK

    render = report.FORMATS[args.format]
    use_color = args.format == "table" and not args.no_color and not args.output and sys.stdout.isatty()
    text = render(result, color=use_color) if args.format == "table" else render(result)
    if args.output:
        with open(args.output, "w") as fh:
            fh.write(text)
    else:
        print(text)

    if fail_on is not None and any(f.severity >= fail_on for f in result.findings):
        return EXIT_FINDINGS
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
