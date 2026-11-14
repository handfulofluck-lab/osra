#!/usr/bin/env sh
# Builds the API image and asserts the three things the old Dockerfile could not: that Node runs, that
# the Prisma CLI resolves, and that the file CMD points at was actually emitted by the build.
#
#   sh services/api/scripts/verify-image.sh               # build from the repo root, then check
#   IMAGE=osra-api:ci SKIP_BUILD=1 sh services/api/scripts/verify-image.sh
#
# CI (.github/workflows/api-image.yml) builds with buildx and runs this with SKIP_BUILD=1.
set -eu

cd "$(dirname "$0")/../../.."   # the repository root is the build context
IMAGE="${IMAGE:-osra-api:local}"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  docker build -f services/api/Dockerfile -t "$IMAGE" .
fi

# 1. Node is present and executable in the runtime stage.
docker run --rm "$IMAGE" node -v

# 2. The Prisma CLI and its engine are IN the image. `--network none` is the point: without a TTY,
#    npx assumes --yes and happily downloads a missing package, so `npx prisma` could pass on an image
#    with no Prisma in it — and a Fargate task in a private subnet cannot download anything.
docker run --rm --network none --workdir /app/services/api "$IMAGE" node_modules/.bin/prisma --version
# 2b. tsx, which runs the seed, is present for the same reason.
docker run --rm --network none --workdir /app/services/api "$IMAGE" node_modules/.bin/tsx --version

# 3. The entry file named by CMD exists in the image (`node dist/server.js`, cwd /app/services/api).
#    `sh -c` rather than `--entrypoint test`: Alpine's test is a shell builtin, not a binary.
docker run --rm "$IMAGE" sh -c 'test -f /app/services/api/dist/server.js'

# 4. The RDS CA bundle is where production's DATABASE_URL says it is (`sslcert=/app/certs/rds-global-bundle.pem`,
#    #766 item 3), it holds certificates, and the user the API runs as can read it and cannot write it. A missing
#    file would only show at the first production boot. The decoy and the checker ship with it.
docker run --rm "$IMAGE" sh -c '
  set -eu
  b=/app/certs/rds-global-bundle.pem
  test -r "$b"
  # `if`, not `! test`: under `set -e` a negated command that fails does not stop the script.
  if test -w "$b"; then echo "the API user can rewrite $b"; exit 1; fi
  test "$(grep -c "BEGIN CERTIFICATE" "$b")" -ge 50
  if grep -q "PRIVATE KEY" /app/certs/*.pem; then echo "a private key is in /app/certs"; exit 1; fi
  test -r /app/certs/decoy-ca.pem
  test -f /app/services/api/scripts/check-db-tls.mjs
'
# 4b. With the switch on, the image refuses to boot on a URL that would not verify (the refusal comes before
#     any connection, so no database is needed), and says why without printing the URL.
out="$(docker run --rm --network none -e DATABASE_TLS_VERIFY=required \
  -e DATABASE_URL="postgresql://u:image-check-pw@db.invalid:5432/x?sslmode=require" \
  -e JWT_SECRET=image-check-not-a-dev-value -e VAULT_KEY=image-check -e CORS_ALLOW_ANY_ORIGIN=1 \
  "$IMAGE" 2>&1 || true)"
echo "$out" | grep -q "sslaccept=strict" || { echo "the image booted, or failed for another reason, on an unverified database URL:"; echo "$out" | tail -5; exit 1; }
if echo "$out" | grep -q "image-check-pw"; then echo "the boot refusal printed the database password"; exit 1; fi

echo "verified: $IMAGE — node, prisma CLI, /app/services/api/dist/server.js and the RDS CA bundle are all present"
