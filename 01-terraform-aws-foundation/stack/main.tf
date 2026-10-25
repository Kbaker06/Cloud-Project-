# The whole environment, composed from the modules. envs/<env> only supplies sizes.

locals {
  name = "${var.project}-${var.environment}"
  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

module "network" {
  source = "../modules/network"

  name             = local.name
  cidr_block       = var.vpc_cidr
  az_count         = var.az_count
  nat_gateway_mode = var.nat_gateway_mode
  tags             = local.tags
}

module "alb" {
  source = "../modules/alb"

  name                = local.name
  vpc_id              = module.network.vpc_id
  public_subnet_ids   = module.network.public_subnet_ids
  certificate_arn     = var.certificate_arn
  deletion_protection = var.environment == "prod"
  tags                = local.tags
}

resource "aws_sns_topic" "alarms" {
  name              = "${local.name}-alarms"
  kms_master_key_id = "alias/aws/sns"
  tags              = local.tags
}

resource "aws_sns_topic_subscription" "alarm_email" {
  count = var.alarm_email == null ? 0 : 1

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

module "app" {
  source = "../modules/ecs-service"

  name                  = "${local.name}-api"
  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  alb_security_group_id = module.alb.security_group_id
  alb_listener_arn      = module.alb.listener_arn
  alb_arn_suffix        = module.alb.arn_suffix

  image            = var.app_image
  cpu              = var.app_cpu
  memory           = var.app_memory
  desired_count    = var.app_min_count
  min_count        = var.app_min_count
  max_count        = var.app_max_count
  use_fargate_spot = var.use_fargate_spot

  environment = {
    APP_ENV = var.environment
    DB_HOST = module.db.endpoint
    DB_PORT = tostring(module.db.port)
    DB_NAME = module.db.database_name
  }

  # The `:password::` suffix makes ECS pull a single JSON key out of the secret.
  secrets = {
    DB_USERNAME = "${module.db.master_user_secret_arn}:username::"
    DB_PASSWORD = "${module.db.master_user_secret_arn}:password::"
  }

  enable_alarms          = true
  alarm_sns_topic_arn    = aws_sns_topic.alarms.arn
  enable_execute_command = var.environment != "prod"
  tags                   = local.tags
}

module "db" {
  source = "../modules/rds"

  name                = "${local.name}-db"
  vpc_id              = module.network.vpc_id
  database_subnet_ids = module.network.database_subnet_ids
  # The SG id is known before the ECS service exists, so there's no dependency cycle.
  allowed_security_groups = { app = module.app.security_group_id }

  instance_class      = var.db_instance_class
  multi_az            = var.db_multi_az
  deletion_protection = var.db_deletion_protection
  skip_final_snapshot = !var.db_deletion_protection
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# CI/CD: GitHub Actions deploy role, scoped to exactly what a deploy needs.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "deploy" {
  statement {
    sid = "RollOutNewTaskDefinitions"
    actions = [
      "ecs:DescribeServices",
      "ecs:DescribeTaskDefinition",
      "ecs:RegisterTaskDefinition",
      "ecs:UpdateService",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "HandRolesToEcs"
    actions   = ["iam:PassRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

module "github_deploy_role" {
  source = "../modules/github-oidc"
  count  = var.github_repository == null ? 0 : 1

  role_name            = "${local.name}-github-deploy"
  github_repository    = var.github_repository
  allowed_subjects     = ["ref:refs/heads/main", "environment:${var.environment}"]
  create_oidc_provider = var.create_github_oidc_provider
  inline_policy_json   = data.aws_iam_policy_document.deploy.json
  tags                 = local.tags
}
