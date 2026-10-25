package main_test

import data.main
import rego.v1

plan(type, after) := {"resource_changes": [{
	"address": sprintf("%s.test", [type]),
	"type": type,
	"change": {"actions": ["create"], "after": after},
}]}

test_ssh_open_to_world_denied if {
	count(main.deny) == 1 with input as plan("aws_vpc_security_group_ingress_rule", {"cidr_ipv4": "0.0.0.0/0", "from_port": 22, "to_port": 22})
}

test_port_range_covering_postgres_denied if {
	some msg in main.deny with input as plan("aws_vpc_security_group_ingress_rule", {"cidr_ipv4": "0.0.0.0/0", "from_port": 5000, "to_port": 6000})
	contains(msg, "5432")
}

test_https_to_world_allowed if {
	count(main.deny) == 0 with input as plan("aws_vpc_security_group_ingress_rule", {"cidr_ipv4": "0.0.0.0/0", "from_port": 443, "to_port": 443})
}

test_ssh_from_vpc_allowed if {
	count(main.deny) == 0 with input as plan("aws_vpc_security_group_ingress_rule", {"cidr_ipv4": "10.0.0.0/16", "from_port": 22, "to_port": 22})
}

test_inline_sg_rule_denied if {
	count(main.deny) == 1 with input as plan("aws_security_group", {"ingress": [{"cidr_blocks": ["0.0.0.0/0"], "from_port": 3389, "to_port": 3389}]})
}

test_public_db_denied if {
	count(main.deny) == 1 with input as plan("aws_db_instance", {"publicly_accessible": true, "storage_encrypted": true, "deletion_protection": true})
}

test_unencrypted_db_denied if {
	count(main.deny) == 1 with input as plan("aws_db_instance", {"publicly_accessible": false, "storage_encrypted": false, "deletion_protection": true})
}

test_good_db_allowed_but_warns_without_deletion_protection if {
	count(main.deny) == 0 with input as plan("aws_db_instance", {"publicly_accessible": false, "storage_encrypted": true, "deletion_protection": false})
	count(main.warn) == 1 with input as plan("aws_db_instance", {"publicly_accessible": false, "storage_encrypted": true, "deletion_protection": false})
}

test_partial_public_access_block_denied if {
	count(main.deny) == 2 with input as plan("aws_s3_bucket_public_access_block", {
		"block_public_acls": true, "ignore_public_acls": true,
		"block_public_policy": false, "restrict_public_buckets": false,
	})
}

test_public_acl_denied if {
	count(main.deny) == 1 with input as plan("aws_s3_bucket_acl", {"acl": "public-read"})
}

test_admin_inline_policy_denied if {
	policy := json.marshal({"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": "*", "Resource": "*"}]})
	count(main.deny) == 1 with input as plan("aws_iam_role_policy", {"policy": policy})
}

test_admin_in_array_form_denied if {
	policy := json.marshal({"Statement": [{"Effect": "Allow", "Action": ["s3:GetObject", "*"], "Resource": ["*"]}]})
	count(main.deny) == 1 with input as plan("aws_iam_policy", {"policy": policy})
}

test_scoped_policy_allowed if {
	policy := json.marshal({"Statement": [{"Effect": "Allow", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::b/*"}]})
	count(main.deny) == 0 with input as plan("aws_iam_policy", {"policy": policy})
}

test_administrator_access_attachment_denied if {
	count(main.deny) == 1 with input as plan("aws_iam_role_policy_attachment", {"policy_arn": "arn:aws:iam::aws:policy/AdministratorAccess"})
}

test_access_keys_denied if {
	count(main.deny) == 1 with input as plan("aws_iam_access_key", {"user": "ci"})
}

test_imdsv1_instance_denied if {
	count(main.deny) == 1 with input as plan("aws_instance", {"metadata_options": [{"http_tokens": "optional"}]})
}

test_imdsv2_instance_allowed if {
	count(main.deny) == 0 with input as plan("aws_instance", {"metadata_options": [{"http_tokens": "required"}]})
}

test_deletes_are_ignored if {
	count(main.deny) == 0 with input as {"resource_changes": [{
		"address": "aws_db_instance.old", "type": "aws_db_instance",
		"change": {"actions": ["delete"], "after": null},
	}]}
}

test_infinite_log_retention_warns if {
	count(main.warn) == 1 with input as plan("aws_cloudwatch_log_group", {"name": "x"})
}
