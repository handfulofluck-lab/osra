# The log group is in base because ECS cannot start a task whose log group is absent, and a
# per-session delete would also throw away the previous session's logs on the next `up`.
resource "aws_cloudwatch_log_group" "api" {
  name = "/ecs/${local.name_prefix}-api"

  # 14 days keeps log ingestion/storage inside the staging budget.
  retention_in_days = 14

  tags = {
    Name = "${local.name_prefix}-api"
  }
}
