# Only the database URL is per-session: it embeds the RDS endpoint and password created in this
# stack. The secret container and the other two values live in base and survive `down`.
resource "aws_secretsmanager_secret_version" "database_url" {
  secret_id = data.terraform_remote_state.base.outputs.database_url_secret_arn

  # sslmode=require encrypts the connection; connection_limit caps each task's Prisma pool so two
  # Fargate tasks cannot exhaust a db.t4g.micro (the API has no pool-size env of its own).
  secret_string = format(
    "postgresql://%s:%s@%s:%d/%s?schema=public&sslmode=require&connection_limit=10",
    aws_db_instance.main.username,
    urlencode(random_password.db.result),
    aws_db_instance.main.address,
    aws_db_instance.main.port,
    aws_db_instance.main.db_name,
  )
}
