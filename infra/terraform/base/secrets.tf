# Secret *containers* live in base so their names survive every `down`; a destroyed container
# would sit in the recovery window and block the next `up` on the same name.

# The API refuses to boot in production with a dev JWT secret (services/api/src/server.ts:30-35).
resource "random_password" "jwt" {
  count = var.secrets_out_of_band ? 0 : 1

  length  = 64
  special = true
}

# VAULT_KEY is a base64-encoded 32-byte AES key (packages/crypto generateFamilyKey); the API
# refuses to boot without it in production (services/api/src/lib/snippetVault.ts:8-11).
resource "random_id" "vault_key" {
  count = var.secrets_out_of_band ? 0 : 1

  byte_length = 32
}

resource "aws_secretsmanager_secret" "database_url" {
  name        = "${local.name_prefix}/database-url"
  description = "Prisma DATABASE_URL for the OSRA ${var.environment} API"

  # Zero-day recovery in staging: a deliberate base rebuild must not wait a week to reuse this name.
  # Production keeps a window so a mistaken delete can be undone (#714).
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret" "jwt_secret" {
  name                    = "${local.name_prefix}/jwt-secret"
  description             = "JWT signing secret for the OSRA ${var.environment} API"
  recovery_window_in_days = var.secret_recovery_window_days # see database_url above
}

# Its value is session-independent, so keeping it here means `up` does not invalidate tokens.
resource "aws_secretsmanager_secret_version" "jwt_secret" {
  count = var.secrets_out_of_band ? 0 : 1

  secret_id     = aws_secretsmanager_secret.jwt_secret.id
  secret_string = random_password.jwt[0].result
}

resource "aws_secretsmanager_secret" "vault_key" {
  name                    = "${local.name_prefix}/vault-key"
  description             = "Base64 32-byte AES key for the server-side snippet vault"
  recovery_window_in_days = var.secret_recovery_window_days # see database_url above
}

# Same reasoning as jwt_secret: a per-session rotation would orphan every stored snippet.
resource "aws_secretsmanager_secret_version" "vault_key" {
  count = var.secrets_out_of_band ? 0 : 1

  secret_id     = aws_secretsmanager_secret.vault_key.id
  secret_string = random_id.vault_key[0].b64_std
}

# The demo parent's password is generated here so the seed never carries a password that is published
# in this repository; no specials keeps it typeable on a phone keyboard.
# Production never seeds a demo parent (up.sh migrates only), so it has no demo password at all (#766 item 6).
resource "random_password" "demo" {
  count = local.demo_password_enabled ? 1 : 0

  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "demo_password" {
  count = local.demo_password_enabled ? 1 : 0

  name                    = "${local.name_prefix}/demo-password"
  description             = "Password of the seeded demo parent; env injects it as SEED_DEMO_PASSWORD"
  recovery_window_in_days = var.secret_recovery_window_days # see database_url above
}

# Kept across sessions like the other two values, so the demo login survives `down` and a re-seed.
resource "aws_secretsmanager_secret_version" "demo_password" {
  count = local.demo_password_enabled ? 1 : 0

  secret_id     = aws_secretsmanager_secret.demo_password[0].id
  secret_string = random_password.demo[0].result
}

# DATABASE_URL is deliberately NOT written here: it embeds the per-session RDS endpoint and
# password, so env owns that version (env/secrets.tf) against this container's ARN.

# FCM service account (roadmap 1.5). The container is Terraform's; the JSON value is not: it is a
# Google-issued credential, so it is written out of band and never appears in state —
#   aws secretsmanager put-secret-value --region <region> \
#     --secret-id <arn> \
#     --secret-string file://<path outside every checkout>
# The API reads it as FCM_SERVICE_ACCOUNT_JSON (services/api/src/lib/push/fcm.ts). A container with
# no value is harmless: nothing maps it into a task until env's push_enabled is true.
resource "aws_secretsmanager_secret" "fcm_service_account" {
  name                    = "${local.name_prefix}/fcm-service-account"
  description             = "Firebase Cloud Messaging service account JSON for the OSRA staging API"
  recovery_window_in_days = var.secret_recovery_window_days # see database_url above
}

# INTERNAL_HMAC_SECRET (#714 requirement, 14 Nov): the global SERVICE credential the ai-engine signs with
# (services/api/src/lib/internalAuth.ts). Generated here, fresh, so production can never inherit a value
# that was ever pasted anywhere; its fingerprint goes into the #637 evidence, never the value. It reaches
# the task only as a `secrets` entry (env/ecs.tf), never as a plain environment variable.
# With secrets_out_of_band (production) the VALUE is written by production-secrets.sh instead, so it is never
# in state; the container stays here so the task definition can name it.
resource "random_password" "internal_hmac" {
  count = var.internal_hmac_secret_enabled && !var.secrets_out_of_band ? 1 : 0

  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "internal_hmac_secret" {
  count = var.internal_hmac_secret_enabled ? 1 : 0

  name                    = "${local.name_prefix}/internal-hmac-secret"
  description             = "INTERNAL_HMAC_SECRET (service credential) for the OSRA ${var.environment} API"
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "internal_hmac_secret" {
  count = var.internal_hmac_secret_enabled && !var.secrets_out_of_band ? 1 : 0

  secret_id     = aws_secretsmanager_secret.internal_hmac_secret[0].id
  secret_string = random_password.internal_hmac[0].result
}

locals {
  demo_password_enabled = var.environment != "production"
}

# Staging's existing demo-password entries keep their addresses.
moved {
  from = random_password.demo
  to   = random_password.demo[0]
}

moved {
  from = aws_secretsmanager_secret.demo_password
  to   = aws_secretsmanager_secret.demo_password[0]
}

moved {
  from = aws_secretsmanager_secret_version.demo_password
  to   = aws_secretsmanager_secret_version.demo_password[0]
}

# Staging's existing values keep their addresses.
moved {
  from = random_password.jwt
  to   = random_password.jwt[0]
}

moved {
  from = random_id.vault_key
  to   = random_id.vault_key[0]
}

moved {
  from = aws_secretsmanager_secret_version.jwt_secret
  to   = aws_secretsmanager_secret_version.jwt_secret[0]
}

moved {
  from = aws_secretsmanager_secret_version.vault_key
  to   = aws_secretsmanager_secret_version.vault_key[0]
}

# --- Values generated outside Terraform (production, #766 items 1 and 3) -------------------------
# Containers only. infra/terraform/production-secrets.sh writes each value once, as the deploy role,
# from a file it creates with mode 600 and deletes; nothing is printed and nothing reaches state.

resource "aws_secretsmanager_secret" "api_db_password" {
  count = var.secrets_out_of_band ? 1 : 0

  name                    = "${local.name_prefix}/api-db-password"
  description             = "Password of the osra_api database role (not the master user); the db-admin task sets it"
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret" "redis_auth_token" {
  count = var.secrets_out_of_band ? 1 : 0

  name                    = "${local.name_prefix}/redis-auth-token"
  description             = "ElastiCache AUTH token (set on the replication group by production-secrets.sh)"
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret" "redis_url" {
  count = var.secrets_out_of_band ? 1 : 0

  name                    = "${local.name_prefix}/redis-url"
  description             = "rediss:// URL with the AUTH token; the API reads it as REDIS_URL"
  recovery_window_in_days = var.secret_recovery_window_days
}
