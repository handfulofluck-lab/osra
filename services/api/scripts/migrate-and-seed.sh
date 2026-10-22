#!/bin/sh
# Migrates the database and seeds the demo family. Runs INSIDE the API image, cwd /app/services/api,
# called by two things that must behave identically: the one-off ECS task in infra/terraform/up.sh and
# the `API image` job in CI.
#
# It deliberately does not use `pnpm`: the runtime stage has no package manager (corepack would fetch
# pnpm at task start, from a private subnet with no route out). The binaries are already in the image,
# so calling them by path is both faster and the only thing that works offline.
set -eu

node_modules/.bin/prisma migrate deploy
node_modules/.bin/tsx scripts/seed.ts
