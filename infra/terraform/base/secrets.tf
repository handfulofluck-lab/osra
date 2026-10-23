# Secret *containers* live in base so their names survive every `down`; a destroyed container
# would sit in the recovery window and block the next `up` on the same name.

# The API refuses to boot in production with a dev JWT secret (services/api/src/server.ts:30-35).
resource "random_password" "jwt" {
  length  = 64
  special = true
}

# VAULT_KEY is a base64-encoded 32-byte AES key (packages/crypto generateFamilyKey); the API
# refuses to boot without it in production (services/api/src/lib/snippetVault.ts:8-11).
resource "random_id" "vault_key" {
  byte_length = 32
}

resource "aws_secretsmanager_secret" "database_url" {
  name        = "${local.name_prefix}/database-url"
  description = "Prisma DATABASE_URL for the OSRA staging API"

  # Zero-day recovery: a deliberate base rebuild must not wait a week to reuse this name.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "jwt_secret" {
  name                    = "${local.name_prefix}/jwt-secret"
  description             = "JWT signing secret for the OSRA staging API"
  recovery_window_in_days = 0 # staging: see database_url above
}

# Its value is session-independent, so keeping it here means `up` does not invalidate tokens.
resource "aws_secretsmanager_secret_version" "jwt_secret" {
  secret_id     = aws_secretsmanager_secret.jwt_secret.id
  secret_string = random_password.jwt.result
}

resource "aws_secretsmanager_secret" "vault_key" {
  name                    = "${local.name_prefix}/vault-key"
  description             = "Base64 32-byte AES key for the server-side snippet vault"
  recovery_window_in_days = 0 # staging: see database_url above
}

# Same reasoning as jwt_secret: a per-session rotation would orphan every stored snippet.
resource "aws_secretsmanager_secret_version" "vault_key" {
  secret_id     = aws_secretsmanager_secret.vault_key.id
  secret_string = random_id.vault_key.b64_std
}

# The demo parent's password is generated here so the seed never carries a password that is published
# in this repository; no specials keeps it typeable on a phone keyboard.
resource "random_password" "demo" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "demo_password" {
  name                    = "${local.name_prefix}/demo-password"
  description             = "Password of the seeded demo parent; env injects it as SEED_DEMO_PASSWORD"
  recovery_window_in_days = 0 # staging: see database_url above
}

# Kept across sessions like the other two values, so the demo login survives `down` and a re-seed.
resource "aws_secretsmanager_secret_version" "demo_password" {
  secret_id     = aws_secretsmanager_secret.demo_password.id
  secret_string = random_password.demo.result
}

# DATABASE_URL is deliberately NOT written here: it embeds the per-session RDS endpoint and
# password, so env owns that version (env/secrets.tf) against this container's ARN.

# FCM service account (roadmap 1.5). The container is Terraform's; the JSON value is not: it is a
# Google-issued credential, so it is written out of band and never appears in state —
#   aws secretsmanager put-secret-value --region <region> --secret-id <arn> #     --secret-string file://<path outside every checkout>
# The API reads it as FCM_SERVICE_ACCOUNT_JSON (services/api/src/lib/push/fcm.ts). A container with
# no value is harmless: nothing maps it into a task until env's push_enabled is true.
resource "aws_secretsmanager_secret" "fcm_service_account" {
  name                    = "${local.name_prefix}/fcm-service-account"
  description             = "Firebase Cloud Messaging service account JSON for the OSRA staging API"
  recovery_window_in_days = 0 # staging: see database_url above
}
