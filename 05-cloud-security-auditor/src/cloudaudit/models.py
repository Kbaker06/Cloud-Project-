from __future__ import annotations

import hashlib
from dataclasses import asdict, dataclass, field
from enum import IntEnum


class Severity(IntEnum):
    INFO = 0
    LOW = 1
    MEDIUM = 2
    HIGH = 3
    CRITICAL = 4

    @classmethod
    def parse(cls, value: str) -> Severity:
        try:
            return cls[value.upper()]
        except KeyError:
            raise ValueError(f"unknown severity {value!r}; choose from {[s.name.lower() for s in cls]}") from None


@dataclass(frozen=True)
class Finding:
    check_id: str
    title: str
    severity: Severity
    resource: str
    region: str
    detail: str
    remediation: str
    category: str = "security"  # or "cost"
    monthly_cost_usd: float | None = None

    @property
    def fingerprint(self) -> str:
        """Stable ID for baselining: same check + same resource = same finding across runs."""
        return hashlib.sha256(f"{self.check_id}|{self.region}|{self.resource}".encode()).hexdigest()[:16]

    def to_dict(self) -> dict:
        d = asdict(self)
        d["severity"] = self.severity.name
        d["fingerprint"] = self.fingerprint
        return d


@dataclass
class CheckError:
    check_id: str
    region: str
    error: str


@dataclass
class ScanResult:
    account_id: str
    regions: list[str]
    findings: list[Finding] = field(default_factory=list)
    errors: list[CheckError] = field(default_factory=list)
    suppressed: int = 0

    def sorted_findings(self) -> list[Finding]:
        return sorted(self.findings, key=lambda f: (-f.severity, f.check_id, f.region, f.resource))

    @property
    def wasted_monthly_usd(self) -> float:
        return round(sum(f.monthly_cost_usd or 0 for f in self.findings), 2)
