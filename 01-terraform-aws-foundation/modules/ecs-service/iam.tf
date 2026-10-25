data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: used by the ECS agent to pull the image, write logs and fetch secrets.
resource "aws_iam_role" "execution" {
  name_prefix        = "${substr(var.name, 0, 20)}-exec-"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  count = length(var.secrets) > 0 ? 1 : 0

  statement {
    sid     = "ReadInjectedSecrets"
    actions = ["secretsmanager:GetSecretValue", "ssm:GetParameters"]
    # Secrets Manager "managed" RDS secrets are referenced as <arn>:password:: — strip the JSON key suffix.
    resources = distinct([for arn in values(var.secrets) : join(":", slice(split(":", arn), 0, min(7, length(split(":", arn)))))])
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  count = length(var.secrets) > 0 ? 1 : 0

  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets[0].json
}

# Task role: what the application code itself is allowed to do. Starts empty — grant per app.
resource "aws_iam_role" "task" {
  name_prefix        = "${substr(var.name, 0, 20)}-task-"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "task_exec" {
  count = var.enable_execute_command ? 1 : 0

  statement {
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task_exec" {
  count = var.enable_execute_command ? 1 : 0

  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_exec[0].json
}
