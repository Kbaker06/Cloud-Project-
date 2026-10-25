resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.database_subnet_ids
  tags       = var.tags
}

resource "aws_security_group" "db" {
  name_prefix = "${var.name}-db-"
  description = "Postgres access for ${var.name}"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-db" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = var.allowed_security_groups

  security_group_id            = aws_security_group.db.id
  description                  = "Postgres from ${each.key}"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = each.value
}

resource "aws_kms_key" "db" {
  description             = "${var.name} RDS storage + Performance Insights"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = var.tags
}

resource "aws_kms_alias" "db" {
  name          = "alias/${var.name}-rds"
  target_key_id = aws_kms_key.db.key_id
}

resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name}-pg16-"
  family      = "postgres16"

  # Reject any client that doesn't speak TLS.
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  # Log anything slower than 500ms — the cheapest performance tool you'll ever have.
  parameter {
    name  = "log_min_duration_statement"
    value = "500"
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.db.arn

  db_name  = var.database_name
  username = var.master_username
  # RDS generates and rotates the password in Secrets Manager. It never touches Terraform state.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  multi_az               = var.multi_az

  backup_retention_period   = var.backup_retention_days
  backup_window             = "03:00-04:00"
  maintenance_window        = "sun:04:30-sun:05:30"
  copy_tags_to_snapshot     = true
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name}-final"

  auto_minor_version_upgrade      = true
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  performance_insights_enabled    = var.performance_insights
  performance_insights_kms_key_id = var.performance_insights ? aws_kms_key.db.arn : null

  iam_database_authentication_enabled = true

  tags = var.tags
}
