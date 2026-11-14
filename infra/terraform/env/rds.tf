resource "aws_db_subnet_group" "main" {
  name       = "${local.name_prefix}-db"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${local.name_prefix}-db"
  }
}

# random_password is the documented fallback for manage_master_user_password = true. The API only
# understands a single DATABASE_URL for Prisma; an RDS-managed secret would have to be read back
# into Terraform (or into a sidecar) to compose that URL, which copies the password into state
# anyway. This keeps the password out of files and inside Secrets Manager, with state encrypted
# at rest in S3.
resource "random_password" "db" {
  count = var.secrets_out_of_band ? 0 : 1

  length = 40
  # RDS master passwords reject '/', '"' and '@'; alphanumeric also keeps the URL safe.
  special = false
}

# Every connection must use TLS (#766 item 9). PostgreSQL 16 on RDS already defaults rds.force_ssl to 1;
# pinning it here means a changed default or a hand edit in the console cannot turn it off unnoticed.
resource "aws_db_parameter_group" "postgres" {
  name        = "${local.name_prefix}-postgres16"
  family      = "postgres16"
  description = "OSRA PostgreSQL 16: TLS required for every connection"

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  tags = {
    Name = "${local.name_prefix}-postgres16"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "main" {
  identifier = "${local.name_prefix}-postgres"
  engine     = "postgres"
  # Major version only: RDS picks the latest 16.x minor, matching docker-compose's PostgreSQL 16.
  engine_version = "16"
  instance_class = var.db_instance_class

  db_name  = "osra"
  username = "osra"
  # Production: RDS generates the master password and keeps it in its own Secrets Manager secret, so it is
  # never in Terraform state (#766 item 1). Only the db-admin task reads it; the API uses osra_api.
  password                    = var.secrets_out_of_band ? null : random_password.db[0].result
  manage_master_user_password = var.secrets_out_of_band ? true : null

  allocated_storage = var.db_allocated_storage
  # 0 = no storage autoscaling (null is how the provider spells "off").
  max_allocated_storage = var.db_max_allocated_storage > 0 ? var.db_max_allocated_storage : null
  storage_type          = "gp3"
  # Encryption stays on: it costs nothing and an unencrypted instance would have to be replaced.
  storage_encrypted = true

  # Off for on-demand staging: a standby buys a test run nothing and doubles the longest part of
  # the apply. Production MUST set db_multi_az = true (ADR-0028 requires a standby).
  multi_az = var.db_multi_az

  # Staging: no automated backups, because the database is thrown away with this stack every session
  # and retention would only pay for snapshots nothing restores. Production keeps 14 days of
  # point-in-time restore (#714).
  backup_retention_period = var.db_backup_retention_days
  backup_window           = var.db_backup_window
  maintenance_window      = var.db_maintenance_window

  # On-demand staging: `down` must be one command, and the database does not survive it anyway.
  # Production turns protection on and keeps a final snapshot (down.sh also refuses production).
  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = var.db_skip_final_snapshot
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${local.name_prefix}-postgres-final"
  copy_tags_to_snapshot     = true

  # Staging applies changes now; production waits for the maintenance window, so a resize or a
  # parameter change never restarts the live database in the middle of the day.
  apply_immediately           = var.environment != "production"
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false

  publicly_accessible = false
  port                = 5432

  parameter_group_name   = aws_db_parameter_group.postgres.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.main.name

  # Staging uses /health/deep and logs. Production turns on Performance Insights at the free 7-day
  # retention so a slow query can be found after the fact.
  # Production exports the PostgreSQL log to the 90-day group in audit_logs.tf (#766 item 2).
  enabled_cloudwatch_logs_exports = local.audit_logs_enabled ? ["postgresql"] : []
  depends_on                      = [aws_cloudwatch_log_group.postgresql]

  performance_insights_enabled          = var.db_performance_insights
  performance_insights_retention_period = var.db_performance_insights ? 7 : null
  monitoring_interval                   = 0
}

moved {
  from = random_password.db
  to   = random_password.db[0]
}
