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
- **The ARM image is not built here.** `linux/arm64` needs QEMU on the runner, so the PR job builds
  `linux/amd64`; the ARM (Fargate, ADR-0028:29) image is built by ECR on push from the same Dockerfile.
- **Not verified where this was written:** there is no Docker on the maintainer's host, so no image was
  built or run locally. Verified instead: `pnpm --filter @familyshield/api run build` (0 errors),
  `pnpm -r --filter "./packages/*" run build`, `node scripts/check-workflows.mjs --strict` (0/0),
  `node scripts/check-docs-links.mjs`, and that `services/api/dist/server.js` is emitted. The image's own
  layers, the pnpm symlinks surviving the cross-stage `COPY`, and the ARM build are proven only by CI
  and by ECR, and are stated as such rather than as "fixed".
