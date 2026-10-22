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

echo "verified: $IMAGE — node, prisma CLI and /app/services/api/dist/server.js are all present"
