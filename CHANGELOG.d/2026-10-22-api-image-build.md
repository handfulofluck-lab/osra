### API image — built from the repo root, with nothing swallowed (#293 review item 7)

The old `services/api/Dockerfile` was nine lines that could not fail. Four faults, each visible in the
file: (1) it was built from the `services/api` context, where `"@familyshield/crypto"` and
`"@familyshield/shared-types"` (`workspace:*`) cannot resolve — they need the root `pnpm-lock.yaml` and
`pnpm-workspace.yaml`; (2) `pnpm install` and `pnpm build` each ended in `|| true`, so a failed install
still produced an image, and the container died at `CMD` instead; (3) there was no `.dockerignore`, so a
Windows `node_modules` and `dist` entered a Linux image; (4) the workspace packages were never copied, so
their TypeScript sources were missing before `pnpm build`.

- **The build is now rooted at the repo root:** `docker build -f services/api/Dockerfile .` (and
  `docker-compose.yml` builds the `api` service with that context and file). pnpm comes from
  `package.json`'s `packageManager` (`pnpm@9.0.0`) through corepack — no pinned copy in the Dockerfile.
- **Two stages, and the install layer is the cache:** the first copies only the root manifests, the
  lockfile and each workspace `package.json` (plus `services/api/prisma/schema.prisma`, because the API's
  `postinstall` is `prisma generate` and fails the install without it), runs
  `pnpm install --frozen-lockfile --filter "@familyshield/api..."`, then copies sources. A `src/` edit
  re-runs the build, not the install.
- **The workspace packages are built before the API** (`pnpm -r --filter "./packages/*" run build`,
  the same command `ci.yml` runs), because the API imports their `dist`, and `prisma generate` runs in
  `services/api` inside the image.
- **No `|| true` anywhere.** A failing install, generate or build fails the image build.
- **The runtime stage is `node:20-alpine`, non-root (`osra`), `EXPOSE 3000`, and runs
  `node dist/server.js`** from `/app/services/api` — the file `tsc` emits from `src/server.ts`
  (`tsconfig.json` `rootDir: src`, `outDir: dist`) and the path `package.json`'s `start` script names. It
  carries `dist`, `prisma/` (for `migrate deploy`), `data/blocklists/pack.json` (read per request by
  `routes/blocklists.ts`), `scripts/seed.ts`, and `node_modules` as installed — not a production-only
  prune, because `prisma` and `tsx` are devDependencies and the seed runs on `tsx`.
- **CI builds it on every pull request:** `.github/workflows/api-image.yml` (own file, so an invalid
  `ci.yml` cannot silence it) runs `docker/setup-buildx-action` + `docker/build-push-action@v6` with
  `push: false` on `linux/amd64` and no credentials, then runs
  `services/api/scripts/verify-image.sh` with `SKIP_BUILD=1`, which asserts `node -v`,
  `npx prisma --version` and the entry file inside the image.
- **CI tests the architecture Fargate runs.** The job uses GitHub's arm64 runner (`ubuntu-24.04-arm`,
  free for public repositories) and builds `linux/arm64` with no QEMU. ECR stores images rather than
  building them — the earlier wording said otherwise and was wrong — so nothing publishes to ECR yet;
  the push step is a follow-up needing an OIDC role scoped to that one repository (#258).
- **CI then does what staging does:** it starts Postgres 16 and Redis 7, runs the seed twice through the
  image and boots it against them, failing the PR unless `/health/deep` answers. A build that cannot
  migrate or seed used to pass every check and fail at the first `up.sh`.
- **One script owns migrate + seed** (`services/api/scripts/migrate-and-seed.sh`), called by both
  `up.sh` and CI, using `node_modules/.bin/prisma` and `node_modules/.bin/tsx`. The runtime image has no
  `pnpm`: corepack would fetch it at task start, from a private subnet with no route out.
- **Not verified where this was written:** there is no Docker on the maintainer's host, so no image was
  built or run locally. Verified instead: `pnpm --filter @familyshield/api run build` (0 errors),
  `pnpm -r --filter "./packages/*" run build`, `node scripts/check-workflows.mjs --strict` (0/0),
  `node scripts/check-docs-links.mjs`, and that `services/api/dist/server.js` is emitted. The reviewer's
  Docker run of an earlier head is what proved the two blockers this revision fixes (a seed that called
  `pnpm`, and `seed-password.ts` missing from the image).
