# syntax=docker/dockerfile:1
#
# Build from the repository root (the API's workspace dependencies resolve only with the root lockfile
# and workspace file):
#   docker build -f services/api/Dockerfile .

# ── build ────────────────────────────────────────────────────────────────────────────────────────────
FROM node:20-alpine AS build

# Prisma's query engine links libssl, which the Node Alpine image does not guarantee.
RUN apk add --no-cache openssl

# pnpm comes from package.json's `packageManager` field, which corepack reads once the manifest is
# copied; the first-run download prompt has no TTY in a build, so it is answered up front.
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable

WORKDIR /app
ENV CI=true

# Manifests only: a source edit must not invalidate the install layer below.
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY packages/crypto/package.json packages/crypto/
COPY packages/shared-types/package.json packages/shared-types/
COPY packages/consent-sdk/package.json packages/consent-sdk/
COPY services/api/package.json services/api/
# The API's postinstall is `prisma generate`, and it fails the install outright when the schema is absent.
COPY services/api/prisma/schema.prisma services/api/prisma/

# `...` installs the API and the workspace packages it depends on — not the clients or the AI engine.
RUN pnpm install --frozen-lockfile --filter "@familyshield/api..."

COPY packages/ ./packages/
COPY services/api/ ./services/api/

# The API imports its workspace dependencies' compiled dist, so they are built before its tsc runs.
RUN pnpm -r --filter "./packages/*" run build
# Run in services/api (pnpm exec's cwd) so the client lands in the store this node_modules resolves
# through. The install's postinstall is not trusted for it: on the dev host it left a misplaced client
# that compiles as implicit `any`.
RUN pnpm --filter @familyshield/api exec prisma generate
RUN pnpm --filter @familyshield/api run build

# ── runtime ─────────────────────────────────────────────────────────────────────────────────────────
FROM node:20-alpine AS runtime

# Same reason as the build stage: the Prisma engine needs libssl at run time too.
RUN apk add --no-cache openssl

WORKDIR /app
ENV NODE_ENV=production

RUN addgroup -S osra && adduser -S osra -G osra

# node_modules is copied as installed rather than pruned to production: `prisma migrate deploy` and the
# seed need `prisma` and `tsx`, which are devDependencies of the API.
COPY --from=build --chown=osra:osra /app/node_modules ./node_modules
COPY --from=build --chown=osra:osra /app/services/api/node_modules ./services/api/node_modules

# The API's imports resolve through workspace links (services/api/node_modules/@familyshield →
# ../../packages/*), so the packages listed in its own package.json as `workspace:*` ship their manifest
# and dist — each COPYed separately, because a directory source copies its contents, not the directory.
COPY --from=build --chown=osra:osra /app/packages/crypto/package.json ./packages/crypto/package.json
COPY --from=build --chown=osra:osra /app/packages/crypto/dist ./packages/crypto/dist
COPY --from=build --chown=osra:osra /app/packages/shared-types/package.json ./packages/shared-types/package.json
COPY --from=build --chown=osra:osra /app/packages/shared-types/dist ./packages/shared-types/dist

# package.json carries `"type": "module"` — without it Node reads dist/*.js as CommonJS and the boot fails.
COPY --from=build --chown=osra:osra /app/services/api/package.json ./services/api/package.json
COPY --from=build --chown=osra:osra /app/services/api/dist ./services/api/dist
# prisma/ for `migrate deploy`; data/ is read per request by routes/blocklists.ts (`../../data/…`).
COPY --from=build --chown=osra:osra /app/services/api/prisma ./services/api/prisma
COPY --from=build --chown=osra:osra /app/services/api/data ./services/api/data
# The seed is scripts/seed.ts, not a prisma/seed; tsx (installed above) runs it as written.
# seed-password.ts is imported by seed.ts (#293), and migrate-and-seed.sh is what up.sh and CI call —
# a single-file COPY here is how the seed shipped without its import once already.
COPY --from=build --chown=osra:osra \
  /app/services/api/scripts/seed.ts \
  /app/services/api/scripts/seed-password.ts \
  /app/services/api/scripts/migrate-and-seed.sh \
  ./services/api/scripts/

USER osra
WORKDIR /app/services/api
EXPOSE 3000
# services/api/package.json `start` is `node dist/server.js`; tsconfig outDir/rootDir make that the emit.
CMD ["node", "dist/server.js"]
