# --- Database administration task (production, #766 item 3) ----------------------------------
# The API connects as `osra_api`, a role that can read and write rows but owns nothing and cannot change
# the schema. Migrations and the role itself are handled by this one-off task, which alone receives the
# RDS-managed master password (never in Terraform state: rds.tf). up.sh runs it after a snapshot:
#   1. prisma migrate deploy as the master user;
#   2. create osra_api if missing, set its password from the api-db-password secret, grant DML on all
#      tables and sequences, and default privileges for tables later migrations create.
# Every connection uses Prisma's verifying TLS form against the RDS CA bundle in the image (#777).
# The password itself never reaches SQL: the task computes a SCRAM-SHA-256 verifier (random salt, 4096
# rounds, RFC 7677) and sends that, which PostgreSQL stores as is. A statement PostgreSQL logs (statement
# logging, a failing statement, Performance Insights) can then hold only the verifier (#781 review B3).
# The task has its OWN execution role: the API's role cannot read the master or the osra_api password.

locals {
  db_admin_enabled = var.secrets_out_of_band
  db_tls_query     = "sslmode=require&sslaccept=strict&sslcert=/app/certs/rds-global-bundle.pem"

  db_admin_script = <<-SH
    set -eu
    case "$API_DB_PASSWORD" in *[!A-Za-z0-9]*|"") echo "api-db-password must be non-empty alphanumeric" >&2; exit 1 ;; esac
    verifier=$(node -e 'const c=require("crypto"),p=process.env.API_DB_PASSWORD,s=c.randomBytes(16),i=4096,k=c.pbkdf2Sync(p,s,i,32,"sha256"),h=(x)=>c.createHmac("sha256",k).update(x).digest(),st=c.createHash("sha256").update(h("Client Key")).digest();process.stdout.write("SCRAM-SHA-256$"+i+":"+s.toString("base64")+"$"+st.toString("base64")+":"+h("Server Key").toString("base64"))')
    case "$verifier" in SCRAM-SHA-256\$4096:*) ;; *) echo "could not compute the SCRAM verifier" >&2; exit 1 ;; esac
    unset API_DB_PASSWORD
    enc=$(node -e 'process.stdout.write(encodeURIComponent(process.env.DB_ADMIN_PASSWORD))')
    export DATABASE_URL="postgresql://$DB_ADMIN_USER:$enc@$DB_HOST:$DB_PORT/$DB_NAME?schema=public&${local.db_tls_query}"
    node_modules/.bin/prisma migrate deploy
    node_modules/.bin/prisma db execute --stdin --url "$DATABASE_URL" <<SQL
    DO \$\$ BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'osra_api') THEN
        CREATE ROLE osra_api LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
      END IF;
    END \$\$;
    ALTER ROLE osra_api PASSWORD '$verifier';
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

# Its own execution role (#781 review): only this task can read the master secret and the osra_api password.
resource "aws_iam_role" "db_admin_execution" {
  count = local.db_admin_enabled ? 1 : 0

  name = "${local.name_prefix}-db-admin-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "db_admin_execution_managed" {
  count = local.db_admin_enabled ? 1 : 0

  role       = aws_iam_role.db_admin_execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "db_admin_secrets" {
  count = local.db_admin_enabled ? 1 : 0

  name = "${local.name_prefix}-db-admin-secrets"
  role = aws_iam_role.db_admin_execution[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ReadMasterAndApiDbPassword"
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue"]
      Resource = [
        aws_db_instance.main.master_user_secret[0].secret_arn,
        data.terraform_remote_state.base.outputs.api_db_password_secret_arn,
      ]
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
  execution_role_arn       = aws_iam_role.db_admin_execution[0].arn

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
