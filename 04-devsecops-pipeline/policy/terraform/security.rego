# Guardrails evaluated against every Terraform plan before apply.
#   terraform show -json tfplan > plan.json && conftest test --policy policy/terraform plan.json
# `deny` blocks the pipeline. `warn` is reported but doesn't block.
package main

import data.terraform.lib
import rego.v1

sensitive_ports := {22, 3389, 3306, 5432, 6379, 27017, 9200}

# --- Network -----------------------------------------------------------------

deny contains msg if {
	some rc in lib.of_type("aws_vpc_security_group_ingress_rule")
	a := lib.after(rc)
	a.cidr_ipv4 == "0.0.0.0/0"
	some port in sensitive_ports
	a.from_port <= port
	port <= a.to_port
	msg := sprintf("%s opens port %d to 0.0.0.0/0", [rc.address, port])
}

deny contains msg if {
	some rc in lib.of_type("aws_security_group")
	some rule in lib.after(rc).ingress
	"0.0.0.0/0" in rule.cidr_blocks
	some port in sensitive_ports
	rule.from_port <= port
	port <= rule.to_port
	msg := sprintf("%s has an inline ingress rule opening port %d to 0.0.0.0/0", [rc.address, port])
}

# --- Data stores ---------------------------------------------------------------

deny contains msg if {
	some rc in lib.of_type("aws_db_instance")
	lib.after(rc).publicly_accessible == true
	msg := sprintf("%s must not be publicly accessible", [rc.address])
}

deny contains msg if {
	some rc in lib.of_type("aws_db_instance")
	lib.after(rc).storage_encrypted != true
	msg := sprintf("%s must have storage_encrypted = true", [rc.address])
}

deny contains msg if {
	some rc in lib.of_type("aws_s3_bucket_public_access_block")
	a := lib.after(rc)
	some setting in ["block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets"]
	a[setting] != true
	msg := sprintf("%s must set %s = true", [rc.address, setting])
}

deny contains msg if {
	some rc in lib.of_type("aws_s3_bucket_acl")
	lib.after(rc).acl in {"public-read", "public-read-write", "authenticated-read"}
	msg := sprintf("%s uses a public canned ACL", [rc.address])
}

# --- IAM -----------------------------------------------------------------------

admin_statement(policy_json) if {
	doc := json.unmarshal(policy_json)
	some stmt in doc.Statement
	stmt.Effect == "Allow"
	"*" in as_array(stmt.Action)
	"*" in as_array(stmt.Resource)
}

as_array(x) := x if is_array(x)

as_array(x) := [x] if not is_array(x)

deny contains msg if {
	some t in {"aws_iam_policy", "aws_iam_role_policy", "aws_iam_user_policy"}
	some rc in lib.of_type(t)
	admin_statement(lib.after(rc).policy)
	msg := sprintf("%s grants Action * on Resource * — write a least-privilege policy", [rc.address])
}

deny contains msg if {
	some rc in lib.of_type("aws_iam_role_policy_attachment")
	lib.after(rc).policy_arn == "arn:aws:iam::aws:policy/AdministratorAccess"
	msg := sprintf("%s attaches AdministratorAccess", [rc.address])
}

deny contains msg if {
	some rc in lib.of_type("aws_iam_access_key")
	msg := sprintf("%s creates a long-lived access key; use roles / OIDC instead", [rc.address])
}

# --- Compute -------------------------------------------------------------------

deny contains msg if {
	some rc in lib.of_type("aws_instance")
	opts := object.get(lib.after(rc), "metadata_options", [])
	not imdsv2_required(opts)
	msg := sprintf("%s must require IMDSv2 (metadata_options.http_tokens = \"required\")", [rc.address])
}

imdsv2_required(opts) if {
	some o in opts
	o.http_tokens == "required"
}

# --- Hygiene (warn only) -------------------------------------------------------

warn contains msg if {
	some rc in lib.of_type("aws_cloudwatch_log_group")
	object.get(lib.after(rc), "retention_in_days", 0) == 0
	msg := sprintf("%s keeps logs forever (and bills you forever); set retention_in_days", [rc.address])
}

warn contains msg if {
	some rc in lib.of_type("aws_db_instance")
	lib.after(rc).deletion_protection != true
	msg := sprintf("%s has deletion_protection disabled", [rc.address])
}
