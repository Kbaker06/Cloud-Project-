from __future__ import annotations

import json

from . import __version__
from .models import ScanResult, Severity
from .registry import all_checks

_COLORS = {
    Severity.CRITICAL: "\033[1;41m",
    Severity.HIGH: "\033[31m",
    Severity.MEDIUM: "\033[33m",
    Severity.LOW: "\033[36m",
    Severity.INFO: "\033[2m",
}
_RESET = "\033[0m"


def _summary_counts(result: ScanResult) -> dict[str, int]:
    counts = {s.name: 0 for s in sorted(Severity, reverse=True)}
    for f in result.findings:
        counts[f.severity.name] += 1
    return counts


def table(result: ScanResult, color: bool = True) -> str:
    rows = [("SEVERITY", "CHECK", "REGION", "RESOURCE", "DETAIL")]
    for f in result.sorted_findings():
        rows.append((f.severity.name, f.check_id, f.region, f.resource, f.detail))
    widths = [min(max(len(r[i]) for r in rows), cap) for i, cap in enumerate((8, 8, 14, 60, 90))]

    def fmt(row, sev=None):
        cells = [c if len(c) <= w else c[: w - 1] + "…" for c, w in zip(row, widths, strict=True)]
        line = "  ".join(c.ljust(w) for c, w in zip(cells, widths, strict=True))
        return f"{_COLORS[sev]}{line}{_RESET}" if color and sev is not None else line

    out = [fmt(rows[0])]
    out += [fmt(r, f.severity) for r, f in zip(rows[1:], result.sorted_findings(), strict=True)]
    counts = " ".join(f"{k.lower()}={v}" for k, v in _summary_counts(result).items())
    out.append("")
    out.append(
        f"account {result.account_id}: {len(result.findings)} findings ({counts}), "
        f"{result.suppressed} suppressed by baseline, ~${result.wasted_monthly_usd}/month of waste"
    )
    for e in result.errors:
        out.append(f"warning: {e.check_id} in {e.region} could not run: {e.error}")
    return "\n".join(out)


def to_json(result: ScanResult) -> str:
    return json.dumps(
        {
            "tool": {"name": "cloudaudit", "version": __version__},
            "account_id": result.account_id,
            "regions": result.regions,
            "summary": {
                **_summary_counts(result),
                "suppressed": result.suppressed,
                "wasted_monthly_usd": result.wasted_monthly_usd,
            },
            "findings": [f.to_dict() for f in result.sorted_findings()],
            "errors": [e.__dict__ for e in result.errors],
        },
        indent=2,
    )


def markdown(result: ScanResult) -> str:
    lines = [
        f"# Cloud audit — account `{result.account_id}`",
        "",
        "| Severity | Count |",
        "|---|---|",
        *[f"| {k} | {v} |" for k, v in _summary_counts(result).items()],
        "",
        f"Estimated waste: **${result.wasted_monthly_usd}/month**. Suppressed by baseline: {result.suppressed}.",
        "",
        "## Findings",
        "",
        "| Severity | Check | Region | Resource | Detail | Fix |",
        "|---|---|---|---|---|---|",
    ]
    esc = lambda s: str(s).replace("|", "\\|")  # noqa: E731
    for f in result.sorted_findings():
        lines.append(
            f"| {f.severity.name} | {f.check_id} | {f.region} | `{esc(f.resource)}` | {esc(f.detail)} | {esc(f.remediation)} |"
        )
    return "\n".join(lines) + "\n"


_SARIF_LEVEL = {
    Severity.CRITICAL: "error",
    Severity.HIGH: "error",
    Severity.MEDIUM: "warning",
    Severity.LOW: "note",
    Severity.INFO: "note",
}


def sarif(result: ScanResult) -> str:
    """SARIF 2.1.0 — upload to GitHub code scanning and findings show up in the Security tab."""
    rules = [{"id": c.id, "name": c.id, "shortDescription": {"text": c.title}} for c in all_checks()]
    results = [
        {
            "ruleId": f.check_id,
            "level": _SARIF_LEVEL[f.severity],
            "message": {"text": f"{f.resource} ({f.region}): {f.detail} Fix: {f.remediation}"},
            "partialFingerprints": {"cloudaudit/v1": f.fingerprint},
            "properties": {"security-severity": {4: "9.5", 3: "8.0", 2: "5.5", 1: "3.0", 0: "1.0"}[int(f.severity)]},
            # Code scanning requires a location; findings are about the account, so anchor them to the README.
            "locations": [{"physicalLocation": {"artifactLocation": {"uri": "05-cloud-security-auditor/README.md"}}}],
        }
        for f in result.sorted_findings()
    ]
    return json.dumps(
        {
            "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
            "version": "2.1.0",
            "runs": [{"tool": {"driver": {"name": "cloudaudit", "version": __version__, "rules": rules}}, "results": results}],
        },
        indent=2,
    )


FORMATS = {"table": table, "json": to_json, "markdown": markdown, "sarif": sarif}
