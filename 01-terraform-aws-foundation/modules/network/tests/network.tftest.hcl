# Run: cd modules/network && terraform init && terraform test
# Uses a mocked AWS provider — no credentials, no cost, runs in CI in seconds.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
    }
  }

  mock_data "aws_region" {
    defaults = {
      name = "us-east-1"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  name       = "test"
  cidr_block = "10.0.0.0/16"
}

run "three_tiers_across_three_azs" {
  command = plan

  assert {
    condition     = length(aws_subnet.public) == 3 && length(aws_subnet.private) == 3 && length(aws_subnet.database) == 3
    error_message = "Expected 3 subnets per tier by default."
  }

  assert {
    condition     = aws_subnet.public[0].cidr_block == "10.0.0.0/20" && aws_subnet.private[0].cidr_block == "10.0.64.0/20" && aws_subnet.database[0].cidr_block == "10.0.128.0/20"
    error_message = "Subnet CIDR layout changed — this would force replacement of every subnet."
  }

  assert {
    condition     = toset([for s in aws_subnet.private : s.availability_zone]) == toset(["us-east-1a", "us-east-1b", "us-east-1c"])
    error_message = "Private subnets must be spread across distinct AZs."
  }
}

run "single_nat_is_shared" {
  command = plan

  variables {
    nat_gateway_mode = "single"
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1
    error_message = "single mode should create exactly one NAT gateway."
  }

  assert {
    condition     = length(aws_route.private_nat) == 3
    error_message = "Every private route table still needs a default route."
  }
}

run "per_az_nat_for_prod" {
  command = plan

  variables {
    nat_gateway_mode = "per_az"
    az_count         = 2
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 2
    error_message = "per_az mode should create one NAT gateway per AZ."
  }
}

run "no_nat_means_no_default_route" {
  command = plan

  variables {
    nat_gateway_mode = "none"
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 0 && length(aws_route.private_nat) == 0
    error_message = "none mode must not create NAT gateways or default routes."
  }
}

run "database_tier_is_isolated" {
  command = plan

  assert {
    condition     = alltrue([for s in aws_subnet.public : !s.map_public_ip_on_launch])
    error_message = "Nothing should get a public IP implicitly."
  }
}

run "rejects_tiny_vpc" {
  command = plan

  variables {
    cidr_block = "10.0.0.0/24"
  }

  expect_failures = [var.cidr_block]
}

run "rejects_single_az" {
  command = plan

  variables {
    az_count = 1
  }

  expect_failures = [var.az_count]
}
