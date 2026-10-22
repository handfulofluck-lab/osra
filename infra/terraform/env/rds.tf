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
  length = 40
  # RDS master passwords reject '/', '"' and '@'; alphanumeric also keeps the URL safe.
  special = false
}

resource "aws_db_instance" "main" {
  identifier = "${local.name_prefix}-postgres"
  engine     = "postgres"
  # Major version only: RDS picks the latest 16.x minor, matching docker-compose's PostgreSQL 16.
  engine_version = "16"
  instance_class = var.db_instance_class

  db_name  = "osra"
  username = "osra"
  password = random_password.db.result

  allocated_storage = 20
  storage_type      = "gp3"
  # Encryption stays on: it costs nothing and an unencrypted instance would have to be replaced.
  storage_encrypted = true

  # Off for on-demand staging: a standby buys a test run nothing and doubles the longest part of
  # the apply. Production MUST set db_multi_az = true (ADR-0028 requires a standby).
  multi_az = var.db_multi_az

  # One day is the smallest retention RDS allows; enough for the pre-launch restore drill.
  backup_retention_period = 1
  backup_window           = "03:00-04:00"

  # On-demand staging: `down` must be one command, and the database does not survive it anyway.
  # Production stacks must turn both on.
  deletion_protection   = false
  skip_final_snapshot   = true
  copy_tags_to_snapshot = true

  # Staging applies changes now rather than waiting for the maintenance window.
  apply_immediately           = true
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false

  publicly_accessible = false
  port                = 5432

  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.main.name

  # Performance Insights has a per-vCPU charge; staging uses /health/deep and logs instead.
  performance_insights_enabled = false
  monitoring_interval          = 0
}
