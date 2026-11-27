# Load test: simulated families against a throw-away copy of the backend

Plan, targets and cost: the load-test plan of 27 Nov 2026 (project files, `testing/load-test/`). Karim approved
**Sunday 29 Nov only, cap US$50**: tiers T1 (1,000 families) and T2 (10,000 families) and the T2 scenarios.

**Never point this at staging or production.** `family-mix.js` refuses any `*.osratech.com` address, and
`infra/terraform/loadtest.sh` refuses before Sat 28 Nov 17:30 UAE, refuses any account but staging, and refuses to run
next to a staging `terraform.tfvars`.

## What is where

| Path | What |
|---|---|
| `infra/terraform/loadtest.sh` | `up` / `seed N` / `run SCENARIO FAMILIES GENERATORS [REF]` / `down` for the load-test stack |
| `infra/terraform/env/loadtest.tf` | Everything gated on `loadtest_mode`: API scope + raised per-address limit + AI stub sidecar + warn logs, the k6 task, the NAT-only ALB rule. Production's guard refuses it |
| `infra/terraform/{base,env}/loadtest.tfvars.example`, `backend/loadtest-*.hcl` | Own base and env, own state keys (`loadtest/...`), staging account, production-like sizes |
| `services/api/scripts/loadtest-seed.ts` | Writes N synthetic families straight into Postgres (refuses outside the load-test stack) |
| `services/api/src/lib/rateLimits.ts` | `RATE_LIMIT_GLOBAL_MAX`, honoured only with `OSRA_DEPLOYMENT_SCOPE=loadtest` |
| `loadtest/ai-stub/server.mjs` | `/analyze` stand-in: fixed safe verdict after 300 ms, no model, no spend |
| `loadtest/k6/family-mix.js` | Scenarios: `smoke`, `steady`, `push_outage`, `storm`, `parent_rush`, `signup`, `sockets` |
| `loadtest/k6/lib/` | `ids.js` (the id rule shared with the seed), `calls.js` (the request mix), `auth.js` (tokens and device signatures minted in k6) |
| `loadtest/smoke/` | Node versions of one pass of the mix and of the parent-rush WebSocket check, to try everything locally first |

## Synthetic families

Family `i` has ids `0000000K-1000-4000-8000-<hex12(i*16+sub)>` (K = 1 family, 2 parent, 3 child, 4 device). Even
families have 2 parents and 3 devices, odd ones 1 parent and 2 devices (1.5 and 2.5 on average). Device tokens and parent
tokens are minted from the load-test stack's own `JWT_SECRET` with the API's claims; device HMAC secrets are
`HMAC(JWT_SECRET, "lt-device:" + deviceId)`. No credentials file exists. Names are `LT Family 000042`, e-mails end in
`.invalid`, there are no push tokens, and nothing is real.

## Local try-out (no AWS)

```bash
# Postgres 16 + Redis on localhost, schema migrated, API built (pnpm --filter @familyshield/api run build)
export DATABASE_URL=postgresql://postgres@localhost:5432/osra JWT_SECRET=<any> VAULT_KEY=$(openssl rand -base64 32)
OSRA_DEPLOYMENT_SCOPE=loadtest LOADTEST_SEED_CONFIRM=synthetic-only LOADTEST_FAMILIES=200 \
  pnpm --filter @familyshield/api exec tsx scripts/loadtest-seed.ts
node loadtest/ai-stub/server.mjs &
OSRA_DEPLOYMENT_SCOPE=loadtest RATE_LIMIT_GLOBAL_MAX=1000000 AI_ENGINE_URL=http://localhost:8000 REDIS_URL=redis://localhost:6379 \
  node services/api/dist/server.js &
API=http://localhost:3000 node loadtest/smoke/node-smoke.mjs   # every call in the mix, expect all 2xx
API=http://localhost:3000 node loadtest/smoke/ws-smoke.mjs     # pause -> phone acks -> other parent's frame
k6 run -e BASE_URL=http://localhost:3000 -e FAMILIES=200 -e SCENARIO=smoke -e DURATION=1m loadtest/k6/family-mix.js
```

## Sunday run (UAE times)

| Time | Step | Who |
|---|---|---|
| 10:00 | `loadtest.sh up -auto-approve` from a separate worktree (about 25 min: RDS Multi-AZ) | Codex |
| 10:30 | `loadtest.sh seed 10000` | Claude |
| 10:45 | `run smoke 1000 1`, then `run steady 1000 1` (T1, 150 req/s) | Claude |
| 11:30 | `run steady 10000 2` (T2, 1,500 req/s) | Claude |
| 12:15 | `run push_outage 10000 3`, `run storm 10000 2`, `run parent_rush 10000 2`, `run signup 10000 2`, `run sockets 10000 1` | Claude |
| 14:30 | If a tier failed: step one size up (API count, RDS class), re-run that tier only, note the step | Claude + Codex |
| by 17:00 | Stop. `loadtest.sh down -auto-approve`; confirm nothing named `osra-loadtest-*` is left | Codex, Claude checks |
| 20:00 | Report to Karim | Claude |

Stop at once and tear down if the Budget alert fires (US$40 = 80% of the cap) or anything named `osra-staging-*`
changes.

## Pass / fail

k6 thresholds: 5xx under 0.1%, device p95 < 300 ms and p99 < 1 s, parent p95 < 500 ms, parent action to the other
parent's WebSocket frame p95 < 2 s. From CloudWatch at the target: API CPU < 60%, RDS CPU < 60%, DB connections < 80%
of max, Valkey CPU < 50%, autoscaling within 3 minutes of a ramp.
