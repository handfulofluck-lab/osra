#!/usr/bin/env bash
# production-secrets.sh — writes production's secret VALUES straight into Secrets Manager, so none of them
# is ever in Terraform state, a file in the repository, a log or a terminal (#766 items 1 and 3).
#
#   AWS_PROFILE=<management profile> ./infra/terraform/production-secrets.sh [--rotate-all]
#
# Run it after base and env are applied and before the first schema phase. Without a flag it is idempotent:
# a secret that already has a current value is left alone, so a second run changes nothing.
# --rotate-all overwrites EVERY value below. It is REQUIRED once on a stack that was applied before
# secrets_out_of_band was turned on (production on 14 Nov 2026): those stacks hold Terraform-written values
# (JWT, vault key, HMAC, database URL) that are also in the state file and its older versions, and removing
# the secret-version resources does not remove the current value (#781 review B2). Afterwards run the
# db-admin task (up.sh's schema phase) so osra_api's password matches. Rotating JWT signs every user out and
# rotating the vault key orphans data sealed with the old one, so on a stack with users this is a planned
# operation, never a routine one.
#
# What it writes (names from base/env outputs):
#   jwt-secret        64 random characters
#   internal-hmac     64 alphanumeric characters (INTERNAL_HMAC_SECRET); its fingerprint is printed
#   vault-key         base64 of 32 random bytes (packages/crypto generateFamilyKey's format)
#   api-db-password   40 alphanumeric characters; the db-admin task sets it on the osra_api role
#   redis-auth-token  64 alphanumeric characters; set on the replication group (ROTATE, then SET)
#   redis-url         rediss://:<token>@<primary endpoint>:6379
#   database-url      postgresql://osra_api:<password>@<RDS endpoint>/osra with Prisma's verifying TLS form
# Values are generated into a private temporary directory (mode 700, files 600), passed to the CLI as
# file:// paths and removed on exit. Nothing is echoed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/secret-gen.sh
. "$HERE/lib/secret-gen.sh"

rotate_all=false
case "${1:-}" in
  "") ;;
  --rotate-all) rotate_all=true ;;
  *) echo "usage: $0 [--rotate-all]" >&2; exit 2 ;;
esac
[ -n "${AWS_PROFILE:-}" ] || { echo "set AWS_PROFILE explicitly" >&2; exit 1; }
export AWS_PAGER=""

out() { terraform -chdir="$HERE/$1" output -raw "$2"; }

region=$(terraform -chdir="$HERE/env" output -raw region 2>/dev/null || echo eu-central-1)
role=$(out env deploy_role_arn)
want_account=$(out env allowed_account_id)
redis_group=$(out env redis_replication_group_id)
redis_host=$(out env redis_primary_endpoint)
db_host=$(out env rds_endpoint | cut -d: -f1)
jwt_arn=$(out base jwt_secret_arn)
vault_arn=$(out base vault_key_secret_arn)
hmac_arn=$(out base internal_hmac_secret_arn)
apidb_arn=$(out base api_db_password_secret_arn)
token_arn=$(out base redis_auth_token_secret_arn)
redis_url_arn=$(out base redis_url_secret_arn)
dburl_arn=$(out base database_url_secret_arn)

for v in apidb_arn token_arn redis_url_arn hmac_arn; do
  case "${!v}" in ""|null) echo "base has no $v: secrets_out_of_band must be true" >&2; exit 1 ;; esac
done

# Act as the production role, and prove the account, exactly as up.sh does.
creds=$(aws sts assume-role --role-arn "$role" --role-session-name osra-production-secrets \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<EOC
$creds
EOC
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION="$region"
unset AWS_PROFILE
[ "$(aws sts get-caller-identity --query Account --output text)" = "$want_account" ] \
  || { echo "refusing: credentials are for another account" >&2; exit 1; }

umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# aws.exe on Windows cannot open a Git Bash path (/tmp/...) given as file://; use the mixed form C:/...
# (15 Nov rotation failed at jwt until TMPDIR pointed at a Windows folder). No-op on Linux and macOS.
if command -v cygpath >/dev/null 2>&1; then tmp=$(cygpath -m "$tmp"); fi

# keep <arn>: true when the secret already has a value and this run must leave it alone.
keep() {
  $rotate_all && return 1
  aws secretsmanager describe-secret --secret-id "$1" --query 'VersionIdsToStages' --output text 2>/dev/null | grep -q AWSCURRENT
}
put() { # put <arn> <file> <label>
  aws secretsmanager put-secret-value --secret-id "$1" --secret-string "file://$2" >/dev/null
  echo "    $3: written"
}
fetch() { aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text; }

echo "==> secrets in account $want_account ($region)$($rotate_all && echo ', rotating all')"

if keep "$jwt_arn"; then echo "    jwt-secret: exists, unchanged"; else
  alnum 64 >"$tmp/jwt"; put "$jwt_arn" "$tmp/jwt" jwt-secret; fi

if keep "$hmac_arn"; then echo "    internal-hmac: exists, unchanged"; else
  alnum 64 >"$tmp/hmac"; put "$hmac_arn" "$tmp/hmac" internal-hmac
  echo "    internal-hmac fingerprint (for #637): $(fingerprint "$tmp/hmac")"; fi

if keep "$vault_arn"; then echo "    vault-key: exists, unchanged"; else
  key32 >"$tmp/vault"; put "$vault_arn" "$tmp/vault" vault-key; fi

if keep "$apidb_arn"; then echo "    api-db-password: exists, unchanged"; else
  alnum 40 >"$tmp/apidb"; put "$apidb_arn" "$tmp/apidb" api-db-password; fi

if keep "$token_arn"; then echo "    redis-auth-token: exists, unchanged"; else
  alnum 64 >"$tmp/token"
  # AUTH on a running TLS group: ROTATE adds the token, SET then makes it the only accepted one.
  for strategy in ROTATE SET; do
    aws elasticache modify-replication-group --replication-group-id "$redis_group" \
      --auth-token "file://$tmp/token" --auth-token-update-strategy "$strategy" --apply-immediately >/dev/null
    aws elasticache wait replication-group-available --replication-group-id "$redis_group"
    echo "    redis AUTH: $strategy done"
  done
  put "$token_arn" "$tmp/token" redis-auth-token
fi

if keep "$redis_url_arn"; then echo "    redis-url: exists, unchanged"; else
  fetch "$token_arn" >"$tmp/token2"
  printf 'rediss://:%s@%s:6379' "$(cat "$tmp/token2")" "$redis_host" >"$tmp/redis_url"
  put "$redis_url_arn" "$tmp/redis_url" redis-url; fi

if keep "$dburl_arn"; then echo "    database-url: exists, unchanged"; else
  fetch "$apidb_arn" >"$tmp/apidb2"
  # Prisma 5 verifies chain and host name only in this form (tested in #777); the host is the RDS name.
  printf 'postgresql://osra_api:%s@%s:5432/osra?schema=public&sslmode=require&sslaccept=strict&sslcert=/app/certs/rds-global-bundle.pem&connection_limit=10' \
    "$(cat "$tmp/apidb2")" "$db_host" >"$tmp/dburl"
  put "$dburl_arn" "$tmp/dburl" database-url; fi

echo "Done. Next: the schema phase (up.sh) runs the db-admin task, which sets osra_api's password from api-db-password."
