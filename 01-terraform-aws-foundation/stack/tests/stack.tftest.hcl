# Plans the *entire* environment against a mocked AWS provider and asserts on the
# security and resilience properties we care about. Run: cd stack && terraform test

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  mock_data "aws_region" {
    defaults = {
      name = "us-east-1"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_vpc" {
    defaults = {
      cidr_block = "10.10.0.0/16"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_db_instance" {
    defaults = {
      master_user_secret = [{
        secret_arn    = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-abc-AbCdEf"
        kms_key_id    = "alias/aws/secretsmanager"
        secret_status = "active"
      }]
    }
  }

  # The AWS provider validates ARN formats even against mocks, so give
  # every ARN-producing resource a realistic-looking value.
  mock_resource "aws_lb" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/cloudlab-dev/50dc6c495c0c9188"
      arn_suffix = "app/cloudlab-dev/50dc6c495c0c9188"
      dns_name   = "cloudlab-dev-123.us-east-1.elb.amazonaws.com"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/tg-abc/73e2d6bc24d8a067"
      arn_suffix = "targetgroup/tg-abc/73e2d6bc24d8a067"
    }
  }

  mock_resource "aws_lb_listener" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/cloudlab-dev/50dc6c495c0c9188/f2f7dc8efc522ab2"
    }
  }

  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:us-east-1:123456789012:cloudlab-dev-alarms"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-role"
    }
  }

  mock_resource "aws_iam_openid_connect_provider" {
    defaults = {
      arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:mock"
    }
  }

  mock_resource "aws_ecs_cluster" {
    defaults = {
      arn = "arn:aws:ecs:us-east-1:123456789012:cluster/mock"
    }
  }

  mock_resource "aws_ecs_task_definition" {
    defaults = {
      arn = "arn:aws:ecs:us-east-1:123456789012:task-definition/mock:1"
    }
  }
}

variables {
  project                = "cloudlab"
  environment            = "dev"
  vpc_cidr               = "10.10.0.0/16"
  az_count               = 2
  nat_gateway_mode       = "single"
  app_image              = "ghcr.io/example/pulse-api:0.1.0"
  app_cpu                = 256
  app_memory             = 512
  app_min_count          = 1
  app_max_count          = 3
  use_fargate_spot       = true
  db_instance_class      = "db.t4g.micro"
  db_multi_az            = false
  db_deletion_protection = false
}

run "dev_plans_cleanly" {
  command = apply # apply against mocks = full graph evaluation, still zero cost

  assert {
    condition     = output.url != ""
    error_message = "The stack must expose a URL."
  }

  assert {
    condition     = module.db.endpoint != null
    error_message = "Database must be created."
  }
}

run "app_receives_rds_managed_secret" {
  command = apply

  assert {
    condition     = output.db_secret_arn == "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-abc-AbCdEf"
    error_message = "The app must receive the RDS-managed secret, not a password variable."
  }
}

run "github_role_only_when_requested" {
  command = apply

  variables {
    github_repository = "kbaker06/Cloud-Project-"
  }

  assert {
    condition     = output.github_deploy_role_arn != null
    error_message = "Setting github_repository should create the deploy role."
  }
}

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment = "production"
  }

  expect_failures = [var.environment]
}
