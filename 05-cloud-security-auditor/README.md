# 05 — Cloud Security & Cost Auditor (build your own Prowler-lite)

> **Goal:** write the tool a cloud security team runs every night. It scans an AWS account across
> regions for the misconfigurations behind real breaches (public buckets, SSH open to the world,
> IMDSv1, root without MFA, stale keys) and for waste (orphaned volumes, idle IPs, ancient snapshots).
> It writes reports people and machines can both read, and it fails CI only on *new* problems.

**Skills you'll be able to claim:** boto3 at scale (pagination, multi-region, concurrency), the
AWS security model (IAM, S3 policies, SGs, IMDS, CloudTrail), CIS AWS Foundations concepts,
FinOps basics, testing cloud code with moto, CLI design, SARIF + GitHub code scanning.

**Maps to:** AWS Security Specialty (SCS-C02), cloud security engineer and FinOps roles, and the
"tell me about a tool you built" interview question.

---

## What it checks

```
$ cloudaudit list-checks
COST-001  ec2         regional  Unattached EBS volume
COST-002  ec2         regional  Unassociated Elastic IP
COST-003  ec2         regional  EBS snapshot older than 180 days
CT-001    cloudtrail  global    No multi-region CloudTrail trail is logging
EC2-001   ec2         regional  Security group exposes sensitive ports to the internet
EC2-002   ec2         regional  EBS volume is not encrypted
EC2-003   ec2         regional  EBS encryption by default is disabled
EC2-004   ec2         regional  Instance allows IMDSv1
IAM-001   iam         global    Root account has access keys
IAM-002   iam         global    Root account has no MFA
IAM-003   iam         global    Console user without MFA
IAM-004   iam         global    Active access key older than 90 days
IAM-005   iam         global    Customer-managed policy grants full admin (*:*)
IAM-006   iam         global    Weak or missing account password policy
RDS-001   rds         regional  Database is publicly accessible
RDS-002   rds         regional  Database storage is not encrypted
RDS-003   rds         regional  Automated backups disabled or too short
S3-001    s3          global    Bucket Block Public Access not fully enabled
S3-002    s3          global    Bucket policy grants access to everyone
S3-003    s3          global    Bucket policy does not enforce TLS
S3-004    s3          global    Bucket versioning disabled
```

Example run against a seeded account:

```
SEVERITY  CHECK     REGION     RESOURCE                      DETAIL
CRITICAL  EC2-001   us-east-1  sg-bbd500f2ca8867196          ssh allows 22/SSH from 0.0.0.0/0
CRITICAL  IAM-002   global     root                          Anyone with the root password owns the account.
HIGH      S3-001    global     arn:aws:s3:::company-backups  Disabled: all four settings
MEDIUM    EC2-002   us-east-1  vol-6437b446721194eed         10 GiB gp2 volume stored in plaintext.
LOW       COST-002  us-east-1  eipalloc-6b566f8895ed3e49b    127.203.120.136 is reserved but unused (~$3.65/month…
...
account 123456789012: 10 findings (critical=2 high=1 medium=2 low=5 info=0), 0 suppressed by baseline, ~$4.65/month of waste
```

## Architecture

```mermaid
flowchart LR
    cli[cli.py<br/>args, exit codes] --> reg[registry.py<br/>@check decorator<br/>glob selection]
    cli --> scan[scanner.py<br/>ThreadPool over<br/>checks × regions]
    scan --> ctx[Context<br/>cached boto3 clients<br/>injectable clock]
    scan --> checks[checks/<br/>s3 · ec2 · iam · rds<br/>cloudtrail · cost]
    checks --> aws[(AWS APIs<br/>read-only)]
    scan -->|AccessDenied → CheckError,<br/>scan continues| result[ScanResult]
    result --> base{baseline?<br/>fingerprint match}
    base --> rep[report.py<br/>table · json · markdown · sarif]
    rep --> gh[GitHub Security tab]
```

Design points:

- **Adding a check is one decorated function.** No registration lists to keep in sync.
- **One missing permission doesn't sink the scan.** Errors are collected and reported per check
  and region, so you still get every finding the role *could* see.
- **Stable fingerprints** (`sha256(check|region|resource)`) make baselines work: adopt the tool on
  a messy account today, and CI fails only when someone adds something *new*.
- **Injectable clock** (`Context(now=...)`) means "key older than 90 days" is tested by moving time,
  not by sleeping for 90 days.
- **Exit codes CI can use:** `0` clean, `2` findings at or above `--fail-on`, `64` usage error.
- **Least privilege:** the scan needs only the AWS-managed `SecurityAudit` policy (read-only).

---

## Build it

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -e '.[dev]'
pytest -v                          # 34 tests, all against moto, no AWS account needed

cloudaudit list-checks
cloudaudit scan                                     # current region, table output
cloudaudit scan --regions all --format markdown -o audit.md
cloudaudit scan --checks 'S3-*,IAM-*' --fail-on critical
cloudaudit scan --regions all --write-baseline baseline.json    # accept today's state...
cloudaudit scan --regions all --baseline baseline.json          # ...fail only on new findings
cloudaudit scan --format sarif -o cloudaudit.sarif              # for GitHub code scanning
```

Run it with a **read-only** role. Never use admin credentials for an auditor:

```bash
aws iam create-role --role-name cloudaudit --assume-role-policy-document file://trust.json
aws iam attach-role-policy --role-name cloudaudit --policy-arn arn:aws:iam::aws:policy/SecurityAudit
```

## Labs

1. **Seed a vulnerable account.** In a sandbox, create a bucket with a public-read policy, an SG with
   22 open to `0.0.0.0/0`, an unencrypted volume, and an IAM user with a console password and no MFA.
   Scan. Fix each finding with the remediation text alone. Did every remediation work as written?
2. **Ship it to the Security tab.** Project 04's `cloud-audit.yml` workflow runs this nightly through
   OIDC and uploads SARIF. Get findings showing up under *Security → Code scanning*.
3. **Scan project 01's infrastructure.** It should come back almost clean. Which findings remain, and
   are they real risks or accepted trade-offs? Write them into a baseline with a justification.
4. **Profile it.** Run `--regions all` with `workers=1` and then `16`. Where does the time go? Which
   AWS APIs throttle first?

## Stretch goals

- [ ] **Multi-account:** take `--role-name`, list accounts via Organizations, assume into each and scan them in parallel.
- [ ] **More checks:** EKS public endpoint, Lambda functions with public URLs, KMS keys without rotation, GuardDuty disabled, unused IAM roles (via `RoleLastUsed`).
- [ ] **Auto-remediation:** `--fix EC2-003,S3-004` with a `--dry-run` default and a confirmation prompt.
- [ ] **Run it serverless:** package it as a Lambda on an EventBridge schedule (reuse project 03's patterns) that posts a Markdown summary to Slack.
- [ ] **Cost Explorer integration:** turn estimated waste into actual last-month spend per finding.
- [ ] Map each check to its **CIS AWS Foundations Benchmark** control ID in the report.

## Interview questions this prepares you for

- What were the root causes of the Capital One breach, and how would you detect them? (SSRF → IMDSv1 → over-permissioned role → S3.)
- How does S3 Block Public Access interact with bucket policies and ACLs?
- How do you roll a new security tool out to an org with 10,000 existing findings without blocking every team?
- How do you test code that calls AWS without calling AWS?
- What's the difference between `SecurityAudit` and `ReadOnlyAccess`, and why does it matter for an auditor?
