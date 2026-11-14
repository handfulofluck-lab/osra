# Server threat model — the API and its production stack

**For:** release security gate #637, box 1 ("threat model read against the build").
**Author:** Claude (Fable, server gate). **Reviewer and owner of the verdict:** Ahmed (security).
**Read from:** `main@da0b3f0c` (2026-11-14), plus the open pull requests named in the last column where a control
is not on `main` yet.
**Scope:** `services/api` and what runs it in production: `infra/terraform/{base,env}` in account `osra-production`,
Frankfurt (`eu-central-1`), per [ADR-0028](../../adr/0028-hosting-regions-and-scaling.md),
[ADR-0030](../../adr/0030-regions-after-uae-outage.md) and
[ADR-0033](../../adr/0033-production-message-scoring.md). The client apps have their own gates (#630 to #636).

This page names what must be protected, who could attack it, and for each threat the control and the place a reader
can check it. It describes the design. It does not describe any unfixed weakness: those live only in the private
`osra-security` repository and are cited here by number.

## 1. What is protected

| # | Asset | Why it matters | Where it lives |
|---|---|---|---|
| A1 | A child's location history | Says where a child is and has been | PostgreSQL, 30 days (ADR-0028 decision 5) |
| A2 | Flagged message excerpts and search text | A child's private words | PostgreSQL, encrypted with `VAULT_KEY` before it is stored (ADR-0006); 90 days |
| A3 | Activity, app use, alerts, rules | A family's daily life | PostgreSQL; 90 days for events, 365 for daily totals |
| A4 | Parent accounts: e-mail, password hash, MFA secret, sessions | Whoever holds one controls a child's device | PostgreSQL (argon2 hashes; MFA secret encrypted), Redis (session caches) |
| A5 | Per-device secrets | Whoever holds one can speak as that child's device | PostgreSQL ([ADR-0003](../../adr/0003-per-device-hmac-agent-auth.md)) |
| A6 | The command channel (lock, pause, ring, rules) | A forged command locks a child out or lets one loose | API, Redis, FCM and APNs |
| A7 | Service secrets: `JWT_SECRET`, `VAULT_KEY`, `INTERNAL_HMAC_SECRET`, database password, push keys | Each one opens A1 to A6 | Secrets Manager; Terraform state |
| A8 | The production account and its deploy path | Whoever can deploy can read everything | AWS IAM, GitHub Actions OIDC, the state bucket |
| A9 | The logs | Kept for months, read outside the database's access rules | CloudWatch |

## 2. Who might attack, and from where

| Actor | Starts with | Wants |
|---|---|---|
| T1 Outsider on the internet | The public address `api.osratech.com` | Any family's data; to take the service down |
| T2 Another family's parent | A valid account of their own | To read or control a child who is not theirs |
| T3 The child | The paired device, and time | To stop being supervised without the parent knowing |
| T4 An invited guardian or co-parent | A valid, limited account | More than the invitation granted |
| T5 Someone who has a parent's password | One credential | The account, and to stay in after the parent notices |
| T6 A compromised dependency, image or CI step | Code that runs in our build or our task | Secrets (A7) |
| T7 Anyone who can use the deploy credential | The management-account deployer, or the machine it sits on | Everything (A8) |
| T8 A reader of logs, backups or state | Read access to one store | Data that should only be in the database |

## 3. Trust boundaries

```
 internet ──TLS 1.2+──> WAF + ALB ──(inside the VPC)──> API tasks ──> PostgreSQL (private subnets)
 parent apps, child agents           public subnets      private         └─> Redis (private subnets)
                                                         subnets  ──443──> FCM / APNs / SES / Play
 GitHub Actions ──OIDC, main only──> ECR (image)                  ──────> Secrets Manager (at task start)
 deployer ──assume role──> osra-production (Terraform)
```

1. **Internet → ALB.** Everything a caller sends is hostile until a guard says otherwise.
2. **ALB → task.** Inside the VPC; the API trusts exactly one proxy hop for the caller's address.
3. **Task → data stores.** The task holds the database password and the cache address.
4. **Build → runtime.** An image is trusted because of how it was built and pushed, not because of its name.
5. **Operator → account.** Terraform runs with rights that include reading A7.

## 4. Threats and controls

"Check" is where a reviewer can see the control hold: a test that fails without it, a Terraform line, or a row of
the live probe (`services/api/scripts/qa-probe.mjs`). "#766 n" is an item of the production hardening list.

### 4.1 At the edge (T1)

| Threat | Control | Check |
|---|---|---|
| Reading traffic in transit | TLS 1.2 and 1.3 only at the ALB; HTTP answers 301 to HTTPS | `infra/terraform/env/ecs.tf` (`ssl_policy = ELBSecurityPolicy-TLS13-1-2-2021-06`) |
| Password guessing, code guessing, floods | Per-route rate limits keyed on the caller's address: 20 a minute on sign-in routes, 10 a minute on a pairing claim, 200 a minute overall; the sign-in and pairing limits fail closed when Redis is down | `services/api/src/lib/rateLimits.ts`; `test/rate-limits.test.ts`, `test/pair-claim-rate-limit.test.ts`, `test/mfa-reset-rate-limit.test.ts` |
| Spoofing the caller's address to dodge those limits | `TRUST_PROXY` is a hop count (1), never `true` | `ecs.tf`; `test/rate-limits.test.ts`; `scripts/check-production-taskdef.mjs` (#778) |
| Known attack traffic and bad-reputation sources | AWS managed WAF rule groups on the ALB; a per-address rate rule (count mode for the first two weeks) | `infra/terraform/env/waf.tf` |
| A hostile web page calling the API with a parent's session | Production must name its browser origins; a wildcard or an unset list refuses to boot | `src/lib/corsConfig.ts`; `test/cors-config.test.ts` |
| Reaching the database or cache directly | Both in private subnets; security groups admit only the API tasks; the database is not publicly accessible | `infra/terraform/env/network.tf`, `rds.tf` |

### 4.2 Between families and between roles (T2, T4)

| Threat | Control | Check |
|---|---|---|
| Reading or changing another family's child, device, rule or alert | Every resource is loaded through the caller's family; a foreign id answers 403 | `src/middleware/requireFamily.ts`; [authz-matrix.md](authz-matrix.md) (one row per route, refusal columns asserted live by probe section Q); `test/security.test.ts` |
| A guardian reading what the invitation did not grant | Reads are gated by the permission on the invite (ADR-0014 amendment) | `test/guardian-reads.test.ts`, `test/sessions-and-roles.test.ts` |
| Processing a child's data after consent is withdrawn | The consent gate answers 428 before the handler runs | `src/middleware/requireConsent.ts`; `test/consent.test.ts` |
| A device token used on a parent route, or the reverse | Role guards on every route group | authz-matrix.md columns `403r`, `403d` |

### 4.3 Accounts and sessions (T5)

| Threat | Control | Check |
|---|---|---|
| A stolen password | Optional TOTP MFA; a used code cannot be replayed, and the replay store failing closes sign-in in production | `src/lib/mfaVerify.ts`; `test/auth.test.ts` |
| Staying signed in after the parent reacts | Logout-all, a password reset or an MFA change bumps a session version held in PostgreSQL; every request is checked against it before any route runs. Redis is a cache the database rebuilds ([ADR-0032](../../adr/0032-durable-revocation.md)) | `src/middleware/sessionGuard.ts`; `test/durable-revocation.test.ts`; `scripts/check-redis-durability.mjs` |
| A stolen refresh token | Rotation with reuse detection: a replayed token revokes the family of tokens | `test/token-hygiene.test.ts` |
| Taking over an account through "I lost my authenticator" | MFA reset needs the e-mail link and a witness on a paired device, with a 24-hour window (ADR-0031) | `test/mfa-reset.test.ts`, `test/mfa-reset-expiry.test.ts` |
| A reset or deletion link read from a log | The request log redacts `token=` and `ticket=` values | `src/lib/logRedaction.ts`; `test/account-deletion-web.test.ts` |
| A JWT on a WebSocket URL | The socket accepts a single-use ticket only ([ADR-0022](../../adr/0022-websocket-ticket-only.md)) | `test/realtime.test.ts` |

### 4.4 The child and the device channel (T3)

| Threat | Control | Check |
|---|---|---|
| Forging a report as another child's device | Each device signs with its own secret, minted at pairing and shown once (ADR-0003); a nonce stops replays, and the nonce store failing closes the route in production | `src/lib/internalAuth.ts`; `test/internal-signing.test.ts` |
| Using a device after the parent removed it | Removal revokes the device; its token answers `401 device_revoked` on every route | `sessionGuard.ts`; `test/durable-revocation.test.ts`; probe |
| Guessing a pairing code | Six digits, short-lived, 10 claims a minute per address, and the parent approves the claim | `test/pairing.test.ts`, `test/pair-claim-rate-limit.test.ts` |
| Going quiet: wiping or uninstalling the agent so nothing reports | The server raises an alert when a device stays silent past its reporting window | `src/jobs/deviceSilence.ts`; `test/device-silence.test.ts` |
| Replaying or forging a parent's command | Commands are rows the server writes; the device fetches them over its signed channel (ADR-0012, ADR-0019) | `test/commands.test.ts` |

What the child can do on the device itself belongs to the client gates and the child-escape catalogue (#736, #737).

### 4.5 Data at rest and in transit inside the stack (T8)

| Threat | Control | Check |
|---|---|---|
| A stolen disk or snapshot | RDS storage encrypted; Redis encrypted at rest | `rds.tf` (`storage_encrypted`), `elasticache.tf` |
| A database dump revealing a child's words | Excerpts are encrypted by the API with `VAULT_KEY` before they reach the database | `src/lib/snippetVault.ts`; `test/content.test.ts` |
| Something inside the VPC answering as the database | The API checks the database's certificate chain and hostname, and refuses to start on a URL that would not | `src/lib/databaseTls.ts`, `scripts/check-db-tls.mjs` (#777); `rds.force_ssl` (#766 9) |
| Reading cache traffic, or writing to the cache from inside the VPC | Redis TLS (`rediss://`), and an AUTH token | `test/redis-url-tls.test.ts`; AUTH is #766 3 |
| Plain HTTP between the ALB and the task | Inside the VPC, security groups admit only the ALB | TLS on the task, or a written acceptance: #766 4 |
| Losing the database | Multi-AZ, 14 days of point-in-time restore, deletion protection, a final snapshot | `rds.tf`, `env/production_guard.tf`; copy outside the account and one restore drill: #766 5 |
| Personal data in logs | No log call names a field a family typed or owns; identifiers only | `test/log-hygiene.test.ts` (#778) |
| Keeping data longer than the privacy policy says | A nightly job deletes past each window; the windows are capped | `src/lib/usageModel.ts`; `test/usage-model.test.ts`; §6 below |
| An account that cannot be erased | Deletion from the app and from a web link removes every child-scoped row | `test/account-deletion.test.ts`; the table-count step in `api-image.yml` |

### 4.6 A child's message leaving the stack (ADR-0033)

| Threat | Control | Check |
|---|---|---|
| A real child's text sent to a model provider outside the EU, or outside our account | At launch no scorer is deployed: `AI_ENGINE_URL` is unset in production and the API scores with its own rules, so **no child's text leaves the API**. When the ADR-0033 service exists it is private to the VPC and calls Bedrock in the EU only | `src/routes/content.ts` (`analyzeContentWithAi` returns `null` without the variable); `check-production-taskdef.mjs` refuses a public `AI_ENGINE_URL` (#778) |
| Model measurement run against production data | The evaluation role exists in staging only | `base/production_guard.tf` (`bedrock_eval_role_enabled` must be false) |

### 4.7 Build and supply chain (T6)

| Threat | Control | Check |
|---|---|---|
| Unreviewed code reaching `main` | `main` is protected; the `verified-gate` check needs a signature at the exact head from a verifier of another model family, and a second key for risk R3 | `.github/workflows/verified-gate.yml`; `scripts/verified-gate-policy.mjs --selftest` |
| An image built from something other than `main` | The publish workflow runs only on `main`, builds `github.sha` and nothing else, and assumes its role by OIDC, with the trust pinned to that one branch. No long-lived key exists | `.github/workflows/api-publish.yml`; `base/oidc.tf`. Production target: #766 8 |
| An image changed after review | Tags are immutable and images are scanned on push; the task definition names a full sha | `base/ecr.tf`; `check-production-taskdef.mjs` (#778); #766 12 |
| A secret committed to the repository | Key-material and PIN checks on every pull request; a full-history scan | `scripts/check-no-service-account-keys.mjs`, `check-no-pins.mjs`; gitleaks in CI: #767 |
| A development switch left on in production | The production task definition is checked against a list of required, allowed and forbidden variables, and every variable the API reads must be on it | `check-production-taskdef.mjs` (#778) |
| A dependency that changes under us | A frozen lockfile in the image build; the image runs as a non-root user | `services/api/Dockerfile` |

### 4.8 Operating the account (T7)

| Threat | Control | Check |
|---|---|---|
| Destroying production by mistake | `down.sh` refuses production; RDS and the ALB carry deletion protection; `up.sh` only applies a plan file that was saved and read | `infra/terraform/down.sh`, `up.sh`; `env/production_guard.tf` |
| Running production with the staging credential, or the reverse | `up.sh` requires a named profile for production and refuses the staging one; the provider pins the account id | #772; `backend/*.hcl` |
| Production created without its protections | Both stacks refuse to plan production unless every protection is set | `*/production_guard.tf`; `*/tests/environments.tftest.hcl` |
| Secrets readable from Terraform state | State bucket versioned, encrypted, TLS-only | Customer key, tighter bucket policy, and `JWT_SECRET` and `VAULT_KEY` out of state: #766 1 and 10 |
| A misused deploy credential | See §5 | osra-security#27; #766 7 |
| An action nobody can reconstruct afterwards | Alarms on the stack's health and a budget alarm | Organisation CloudTrail, GuardDuty and the ALB, VPC, WAF and PostgreSQL logs: #766 2 |

## 5. Open items for this gate

Each is tracked where its detail may be written. This page gives the number only.

| Item | State on 2026-11-14 | Needed for sign-off |
|---|---|---|
| osra-security#27 (who can deploy to production, and how) | Open | Closed, or accepted by Karim in writing on #637 |
| osra-security#14, #15, #20, #26 | Open; Ahmed to say which belong to this gate | Triage, then closed or accepted |
| #766 items 1 to 13 | Batches A to D, 15 to 17 Nov | Merged and applied before the service phase |
| #777, #778 | In review | Merged |
| #772, #767 | In review | Merged |

## 6. What the configuration must match in the published privacy policy

`site/privacy/index.html` makes these promises. A setting that breaks one is a finding for box 6 of the gate.

| Promise | Setting that keeps it |
|---|---|
| Location history: 30 days | `LOCATION_RETENTION_DAYS` unset (default 30) or at most 30 |
| Activity events and stored message excerpts: 90 days | `RETENTION_DAYS` unset or at most 90 |
| Daily app-use totals: 365 days | `ROLLUP_RETENTION_DAYS` |
| Each encrypted database backup is deleted within 90 days | Point-in-time restore is 14 days. A backup copy outside the account (#766 5) must expire within 90 days |
| Server logs hold identifiers and no messages or content, for at most 90 days | `test/log-hygiene.test.ts`; log retention of **exactly 90 days** satisfies both this ceiling and the security floor asked for in #766 11 |
| Data is stored in the EU | Every resource in `eu-central-1`; secrets resolve from `eu-central-1` ARNs only |

## 7. What this model does not cover

- The client apps, the stores' review of them and what a child can do on a device.
- AWS itself, GitHub itself, and the availability of a single region (ADR-0030 accepts one region at launch).
- A parent who chooses to share their password. MFA limits it; nothing prevents it.
- Abuse of the product by a parent against a child or another adult. That is a product and policy question, held in
  the consent design (ADR-0008) and not a property of the server.

## 8. How to read this against a build

1. Take the candidate sha named on #637.
2. For each row of §4, open the "Check" and confirm it exists at that sha and is green: `pnpm --filter
   @familyshield/api test`, the Terraform tests in `terraform.yml`, and the probe run linked in the "Row 8 evidence"
   comment.
3. For each row that cites a #766 item or an open pull request, confirm it merged before that sha.
4. §5 must be empty of open items, or each one carries Karim's written acceptance on #637.
