# Optional: the IAM roles the GitHub Actions workflows in .github/workflows assume via OIDC.
#   terraform apply -var budget_email=... -var github_repository=owner/repo
# Then set the printed role ARNs as repository *variables* (not secrets — they aren't secret).
#
#   plan  role  ← PRs + main          ReadOnlyAccess + read-only state. Can't change anything.
#   apply role  ← environment:dev     Scoped power-user. Only runs after the GitHub Environment's
#                                     required reviewers approve.
#   audit role  ← main branch         SecurityAudit for the nightly cloudaudit scan (project 05).

variable "github_repository" {
  description = "owner/repo allowed to assume the CI roles. Null = don't create them."
  type        = string
  default     = null
}

variable "name_prefix" {
  description = "Resources the apply role may manage in IAM must be named with this prefix."
  type        = string
  default     = "cloudlab"
}

locals {
  github     = var.github_repository != null
  account_id = data.aws_caller_identity.current.account_id
  oidc_host  = "token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = local.github ? 1 : 0

  url             = "https://${local.oidc_host}"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_trust" {
  for_each = local.github ? {
    plan  = ["pull_request", "ref:refs/heads/main"]
    apply = ["environment:dev"]
    audit = ["ref:refs/heads/main"]
  } : {}

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = [for s in each.value : "repo:${var.github_repository}:${s}"]
    }
  }
}

resource "aws_iam_role" "github" {
  for_each = data.aws_iam_policy_document.github_trust

  name                 = "github-${each.key}"
  assume_role_policy   = each.value.json
  max_session_duration = 3600
}

# --- plan --------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "plan_readonly" {
  count      = local.github ? 1 : 0
  role       = aws_iam_role.github["plan"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Plan only READS state (PR plans run with -lock=false). Only the approved apply job can write it,
# so a malicious pull request can't tamper with state.
data "aws_iam_policy_document" "state_read" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
}

data "aws_iam_policy_document" "state_write" {
  source_policy_documents = [data.aws_iam_policy_document.state_read.json]
  statement {
    sid       = "WriteStateAndLockfiles"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
}

resource "aws_iam_role_policy" "state_access" {
  for_each = local.github ? {
    plan  = data.aws_iam_policy_document.state_read.json
    apply = data.aws_iam_policy_document.state_write.json
  } : {}

  name   = "terraform-state"
  role   = aws_iam_role.github[each.key].id
  policy = each.value
}

# --- apply -------------------------------------------------------------------
# PowerUserAccess is everything except IAM/Organizations. Stacks still need to create roles, so
# grant IAM write — but only on resources whose name starts with the project prefix.
resource "aws_iam_role_policy_attachment" "apply_poweruser" {
  count      = local.github ? 1 : 0
  role       = aws_iam_role.github["apply"].name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "apply_iam" {
  statement {
    sid     = "ManageProjectRolesAndPolicies"
    actions = ["iam:*"]
    resources = [
      "arn:aws:iam::${local.account_id}:role/${var.name_prefix}-*",
      "arn:aws:iam::${local.account_id}:policy/${var.name_prefix}-*",
      "arn:aws:iam::${local.account_id}:oidc-provider/${local.oidc_host}",
    ]
  }
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/aws-service-role/*"]
  }
  statement {
    sid       = "ReadIam"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "apply_iam" {
  count  = local.github ? 1 : 0
  name   = "scoped-iam"
  role   = aws_iam_role.github["apply"].id
  policy = data.aws_iam_policy_document.apply_iam.json
}

# --- audit -------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "audit" {
  count      = local.github ? 1 : 0
  role       = aws_iam_role.github["audit"].name
  policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

output "github_role_arns" {
  description = "Set as repository variables AWS_PLAN_ROLE_ARN / AWS_APPLY_ROLE_ARN / AWS_AUDIT_ROLE_ARN."
  value       = { for k, r in aws_iam_role.github : k => r.arn }
}
