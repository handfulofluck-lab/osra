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

# DATABASE_URL is deliberately NOT written here: it embeds the per-session RDS endpoint and
# password, so env owns that version (env/secrets.tf) against this container's ARN.
