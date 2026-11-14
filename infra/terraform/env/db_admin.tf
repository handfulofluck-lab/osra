# --- Database administration task (production, #766 item 3) ----------------------------------
# The API connects as `osra_api`, a role that can read and write rows but owns nothing and cannot change
# the schema. Migrations and the role itself are handled by this one-off task, which alone receives the
# RDS-managed master password (never in Terraform state: rds.tf). up.sh runs it after a snapshot:
#   1. prisma migrate deploy as the master user;
#   2. create osra_api if missing, set its password from the api-db-password secret, grant DML on all
#      tables and sequences, and default privileges for tables later migrations create.
# Every connection uses Prisma's verifying TLS form against the RDS CA bundle in the image (#777).
# The password reaches SQL only inside the container; it is alphanumeric (production-secrets.sh), so it
# needs no quoting beyond the literal.

locals {
  db_admin_enabled = var.secrets_out_of_band
  db_tls_query     = "sslmode=require&sslaccept=strict&sslcert=/app/certs/rds-global-bundle.pem"

  db_admin_script = <<-SH
    set -eu
    case "$API_DB_PASSWORD" in *[!A-Za-z0-9]*|"") echo "api-db-password must be non-empty alphanumeric" >&2; exit 1 ;; esac
    enc=$(node -e 'process.stdout.write(encodeURIComponent(process.env.DB_ADMIN_PASSWORD))')
    export DATABASE_URL="postgresql://$DB_ADMIN_USER:$enc@$DB_HOST:$DB_PORT/$DB_NAME?schema=public&${local.db_tls_query}"
    node_modules/.bin/prisma migrate deploy
    node_modules/.bin/prisma db execute --stdin --url "$DATABASE_URL" <<SQL
    DO \$\$ BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'osra_api') THEN
        CREATE ROLE osra_api LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
      END IF;
    END \$\$;
    ALTER ROLE osra_api PASSWORD '$API_DB_PASSWORD';
    REVOKE CREATE ON SCHEMA public FROM PUBLIC;
    GRANT CONNECT ON DATABASE $DB_NAME TO osra_api;
    GRANT USAGE ON SCHEMA public TO osra_api;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO osra_api;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO osra_api;
    ALTER DEFAULT PRIVILEGES FOR ROLE $DB_ADMIN_USER IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO osra_api;
    ALTER DEFAULT PRIVILEGES FOR ROLE $DB_ADMIN_USER IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO osra_api;
    SQL
    echo "db-admin: migrations applied, osra_api granted"
  SH
}

# The execution role pulls the two secrets this task needs. The RDS-managed secret exists only in env.
resource "aws_iam_role_policy" "db_admin_secrets" {
  count = local.db_admin_enabled ? 1 : 0

  name = "${local.name_prefix}-db-admin-secrets"
  role = data.terraform_remote_state.base.outputs.execution_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadRdsManagedMasterSecret"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_db_instance.main.master_user_secret[0].secret_arn]
    }]
  })
}

resource "aws_ecs_task_definition" "db_admin" {
  count = local.db_admin_enabled ? 1 : 0

  family                   = "${local.name_prefix}-db-admin"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = data.terraform_remote_state.base.outputs.execution_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = "db-admin"
      image     = var.api_image
      essential = true
      command   = ["sh", "-c", local.db_admin_script]

      environment = [
        { name = "DB_HOST", value = aws_db_instance.main.address },
        { name = "DB_PORT", value = tostring(aws_db_instance.main.port) },
        { name = "DB_NAME", value = aws_db_instance.main.db_name },
        { name = "DB_ADMIN_USER", value = aws_db_instance.main.username },
      ]

      secrets = [
        { name = "DB_ADMIN_PASSWORD", valueFrom = "${aws_db_instance.main.master_user_secret[0].secret_arn}:password::" },
        { name = "API_DB_PASSWORD", valueFrom = data.terraform_remote_state.base.outputs.api_db_password_secret_arn },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = data.terraform_remote_state.base.outputs.log_group_name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "db-admin"
        }
      }
    }
  ])

  tags = {
    Name = "${local.name_prefix}-db-admin"
  }
}
