# Server threat model — the API and its production stack

**For:** release security gate #637, box 1 ("threat model read against the build").
**Author:** Claude (Fable, server gate). **Reviewer and owner of the verdict:** Ahmed (security).
**Read from:** the gate candidate `main@7be1a92b` (named on #637, 2026-11-17); the candidate is now `main@0036d6b9`, which adds only #886, and Ahmed's read against it (#637 comment 6957582839) is folded in on 2026-11-18. First pass `main@da0b3f0c`
(2026-11-14); this second pass takes Antigravity's completeness read (#780 comment 6884240350) and what batches A to F
of #766 put in place. Where a control exists in code but is not yet live in production, the row says so.
**Scope:** `services/api` and what runs it in production: `infra/terraform/{base,env}` in account `osra-production`,
Frankfurt (`eu-central-1`), and `infra/terraform/org-audit` in the management account (organisation CloudTrail with
Object Lock, GuardDuty in both regions, the locked backup copy vault in `eu-west-1`, Identity Center and the
deployer's guardrails), per [ADR-0028](../../adr/0028-hosting-regions-and-scaling.md),
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
| A3 | Activity, app use, alerts, rules | A family's daily life | PostgreSQL; 90 days for events, 365 for daily totals, 12 months for alerts |
| A10 | The family's subscription state | A forged entitlement gives the paid product away; a forged cancellation takes it from a paying family | PostgreSQL; the truth is Google Play's (ADR-0041) |
| A4 | Parent accounts: e-mail, password hash, MFA secret, sessions | Whoever holds one controls a child's device | PostgreSQL (argon2 hashes; MFA secret encrypted), Redis (session caches) |
| A5 | Per-device secrets | Whoever holds one can speak as that child's device | PostgreSQL, encrypted with `VAULT_KEY` before it is stored (#839; [ADR-0003](../../adr/0003-per-device-hmac-agent-auth.md)) |
| A6 | The command channel (lock, pause, ring, rules) | A forged command locks a child out or lets one loose | API, Redis, FCM and APNs |
| A7 | Service secrets: `JWT_SECRET`, `VAULT_KEY`, `INTERNAL_HMAC_SECRET`, database passwords, push keys | Each one opens A1 to A6 | Secrets Manager only. Production writes them out of band (`secrets_out_of_band`, batch B #781; `production-secrets.sh`), so Terraform state holds their names, never their values |
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
| Known attack traffic and bad-reputation sources | AWS managed WAF rule groups on the ALB block from the first day. The WAF's own per-address rate rule only **counts** at launch (`waf_rate_action = "count"`) and is switched to block after two weeks of real traffic, so that families behind one carrier address are not locked out. Until then the limits that enforce are the API's per-route limits in the row above | `infra/terraform/env/waf.tf` (`waf_rate_action`, `waf_rate_limit`). Day 0: managed groups block, rate rule counts. Day 14: a reviewed change sets `block` |
| A hostile web page calling the API with a parent's session | Production must name its browser origins; a wildcard or an unset list refuses to boot | `src/lib/corsConfig.ts`; `test/cors-config.test.ts` |
| Reaching the database or cache directly | Both in private subnets; security groups admit only the API tasks; the database is not publicly accessible | `infra/terraform/env/network.tf`, `rds.tf` |
| Oversized requests | Fastify's default body limit (1 MiB) on every route, smaller limits on the form pages (1 to 8 KiB), and batch arrays capped in the route schemas. The WAF's managed body-size rule only **counts** (`SizeRestrictions_BODY` overridden in `waf.tf`), because some legitimate batches pass 8 KB; the API's own limits are the ones that enforce | `src/server.ts` (no `bodyLimit` override), `src/routes/linkPages.ts`, `account.ts`, `digests.ts`; `env/waf.tf` |

### 4.2 Between families and between roles (T2, T4)

| Threat | Control | Check |
|---|---|---|
| Reading or changing another family's child, device, rule or alert | Every resource is loaded through the caller's family; a foreign id answers 403 | `src/middleware/requireFamily.ts`; [authz-matrix.md](authz-matrix.md) (one row per route, refusal columns asserted live by probe section Q); `test/security.test.ts` |
| A guardian reading what the invitation did not grant | Reads are gated by the permission on the invite (ADR-0014 amendment) | `test/guardian-reads.test.ts`, `test/sessions-and-roles.test.ts` |
| Processing a child's data after consent is withdrawn | The consent gate answers 428 before the handler runs | `src/middleware/requireConsent.ts`; `test/consent.test.ts` |
| A forged proof that the adult accepted the terms (#875, #878, #886) | The stored hash and version come from the copy the server served, never from the request | `test/register-consent.test.ts` ("stores the served hash, version and surface") |
| An account created without its consent record | The consent row is written through the same transaction as the account; a failed insert leaves no account and no session | `test/register-consent.test.ts` ("writes the account and its consent row through the same transaction client", "a failed consent insert leaves no session") |
| Reading or writing another parent's consent | The `/v1/me` consent routes are scoped to the token's `sub` | `test/consent-routes.test.ts` (state read, row written and history scoped to the signed-in parent) |
| Flooding the consent history with repeat writes | A repeat of the newest state appends nothing | `test/consent-routes.test.ts` ("a repeat of the newest state is not a second consent act") |
| The public consent copy route | Read-only, `cache-control: no-store`, under the global rate limit | `src/routes/consentCopy.ts`; `test/consent-copy.test.ts` |
| A device token used on a parent route, or the reverse | Role guards on every route group | authz-matrix.md columns `403r`, `403d` |

### 4.3 Accounts and sessions (T5)

| Threat | Control | Check |
|---|---|---|
| A stolen password | Optional TOTP MFA; a used code cannot be replayed, and the replay store failing closes sign-in in production | `src/lib/mfaVerify.ts`; `test/auth.test.ts` |
| Staying signed in after the parent reacts | Logout-all, a password reset or an MFA change bumps a session version held in PostgreSQL; every request is checked against it before any route runs. Redis is a cache the database rebuilds ([ADR-0032](../../adr/0032-durable-revocation.md)) | `src/middleware/sessionGuard.ts`; `test/durable-revocation.test.ts`; `scripts/check-redis-durability.mjs` |
| A stolen refresh token | Rotation with reuse detection: a replayed token revokes the family of tokens | `test/token-hygiene.test.ts` |
| Taking over an account through "I lost my authenticator" | MFA reset needs the e-mail link (single use, 30 minutes) and a witness on a paired device. The witness must land within 24 hours of the mailbox confirmation (`MFA_RESET_WITNESS_DEADLINE_MS`), and a 72-hour reset window starts when it passes (`MFA_RESET_WINDOW_MS`), during which the parent can cancel (ADR-0031) | `test/mfa-reset.test.ts`, `test/mfa-reset-expiry.test.ts` |
| A reset or deletion link read from a log | The request log redacts `token=` and `ticket=` values | `src/lib/logRedaction.ts`; `test/account-deletion-web.test.ts` |
| A JWT on a WebSocket URL | The socket accepts a single-use ticket only ([ADR-0022](../../adr/0022-websocket-ticket-only.md)) | `test/realtime.test.ts` |

### 4.3a Mailed links and invitations (T1, T4, T5)

| Threat | Control | Check |
|---|---|---|
| Using an old or already-used link | A password reset token lives 15 minutes, is single use, and a newer request supersedes it. An invitation lives 7 days, is bound to the invited address (403 on a mismatch) and answers 409 once it is no longer pending. A digest confirmation is single use and lives 24 hours | `src/routes/auth.ts` (reset), `src/routes/invites.ts` (`INVITE_TTL_SECONDS`), `src/routes/digests.ts`; `test/invites.test.ts`, `test/digests-abuse.test.ts` |
| Using our mail to pester a stranger | Invitations and digest recipients are limited per family per day; a digest goes to a non-parent address only after that address confirms; at most five recipients | `test/invites.test.ts`, `test/digests-abuse.test.ts` |
| A mail scanner that follows links confirming something | A link that changes state opens a page with a button; the change is a POST. This holds for all six mailed links: deletion, digest confirmation, password reset, MFA reset confirm and cancel, invitation | `test/digests-abuse.test.ts` ("the confirmation button works from a browser"); `test/account-deletion-web.test.ts`; `test/link-pages.test.ts` (L1, L6, L7, L13) |
| Someone who can read the invited mailbox joining the family with the link alone | The invitation page asks for the account's password, and the authenticator code when two-step verification is on, before anyone is moved. A wrong password leaves the invitation usable and counts against the auth rate limit | `src/routes/linkPages.ts` (`POST /invite/accept`); `test/link-pages.test.ts` (L16, L17, L18) |
| An inviter using the invitation page against an address they chose: guessing its password, or learning whether it has an account or MFA | The link carries a secret that exists only in the mail (256 random bits; Redis keeps its SHA-256), not the invite id the inviter sees. The page is identical for every live invitation, and every refusal is one answer after one password verification | `src/routes/invites.ts` (`inviteIdForSecret`); `test/link-pages.test.ts` (L14, L20, L21, L22) |
| One of our pages shown inside another site's frame, to trick a press of its button | `frame-ancestors 'none'` and `X-Frame-Options: DENY` on every page | `src/lib/htmlPage.ts` (`sendPage`); `test/link-pages.test.ts` (`expectPageHeaders`) |
| A token in a link leaking through the log, the referrer or a cached page | The request log drops `?token=`; every page is `no-store`, `no-referrer`, loads nothing from another origin and runs no script; the token moves to a hidden form field on the first POST; nothing user-supplied is rendered | `src/lib/logRedaction.ts`, `src/lib/htmlPage.ts` (`sendPage`); `test/link-pages.test.ts` (L1, L5) |
| Learning from the reset form whether an address has an account, or flooding a parent with reset mail | A reset request answers the same for a known and an unknown address, and one link per address per minute is issued, claimed before the account is looked up | `test/auth.test.ts` ("reset/request never reveals whether the email exists", "#167") |

The API serves the page behind every mailed link itself (`src/routes/linkPages.ts`, #789; deletion and the digest
confirmation already did), so the links work wherever `APP_PUBLIC_URL` points at the API. The pages add no second
implementation of a state change: the reset and MFA reset pages call the existing JSON routes in-process, with the
caller's address passed on so the auth rate limit counts the person, and the invitation page calls the same
`acceptInvite` the JSON route calls.

### 4.3b Subscription state (A10; T1, T2, T4)

| Threat | Control | Check |
|---|---|---|
| A forged purchase | The API never believes the app: it asks Google Play for the purchase's state with its own service account, and only the family's owner may submit one | `src/routes/billing.ts` (`/google/verify`, `requireOwner`); `test/billing.test.ts`, `test/billing-play.test.ts` |
| A forged or replayed Play notification | The notification endpoint accepts only a token Google signed for our audience and our named sender; without that configuration it answers 503. The notification's content is never the state: every one makes the API re-read the subscription from Play, so a replay re-reads the same truth | `src/routes/billing.ts` (`/google/rtdn`, `pushVerifier`); `test/billing-play.test.ts` ("refuses a token signed by anyone else", "refuses an expired token") |

Open private item for this area: osra-security#15 (§5).

### 4.4 The child and the device channel (T3)

| Threat | Control | Check |
|---|---|---|
| Forging a report as another child's device | Each device signs with its own secret, minted at pairing and shown once (ADR-0003); a nonce stops replays, and the nonce store failing closes the route in production | `src/lib/internalAuth.ts`; `test/internal-signing.test.ts` |
| Reading every device's secret from a database copy (T8) | The secret is stored under `VAULT_KEY` and decrypted only to check a signature; a value that does not decrypt counts as no secret; a row from before the change is re-stored encrypted after it next verifies | `src/lib/internalAuth.ts` (`deviceKey`, `sealLegacyKey`); `test/device-key-at-rest.test.ts` (K1 to K6), `test/pairing.test.ts` (osra-security#14, #839) |
| Using a device after the parent removed it | Removal revokes the device; its token answers `401 device_revoked` on every route | `sessionGuard.ts`; `test/durable-revocation.test.ts`; probe |
| Guessing a pairing code | Six digits, short-lived, 10 claims a minute per address, and the parent approves the claim | `test/pairing.test.ts`, `test/pair-claim-rate-limit.test.ts` |
| Going quiet: wiping or uninstalling the agent so nothing reports | The server raises an alert when a device stays silent past its reporting window | `src/jobs/deviceSilence.ts`; `test/device-silence.test.ts` |
| A paired device reporting or asking as a sibling's device | A device's signature binds it to its own device row and child: a request that names another child answers `400 cross_child_content_forbidden`, another device `400 device_mismatch`. The shared `INTERNAL_HMAC_SECRET` is for services inside the stack, never for a device, and its callers are listed | `src/routes/content.ts` (the `auth.device` checks); [authz-matrix.md](authz-matrix.md); `test/internal-signing.test.ts` |
| Replaying or forging a parent's command | Commands are rows the server writes; the device fetches them over its signed channel (ADR-0012, ADR-0019) | `test/commands.test.ts` |

What the child can do on the device itself belongs to the client gates and the child-escape catalogue (#736, #737).

### 4.5 Data at rest and in transit inside the stack (T8)

| Threat | Control | Check |
|---|---|---|
| A stolen disk or snapshot | RDS storage encrypted with the stack's own customer key (alias `osra-production-rds`), with an alarm on any change to that key's state; Redis encrypted at rest | `rds.tf` (`kms_key_id`, `db_customer_kms_key`), `alarms.tf` (`rds-key-danger`), `elasticache.tf`; batch D #783 |
| The API's database login doing more than read and write rows | The API connects as `osra_api`: it can read and write rows, owns nothing and cannot change the schema or roles. Migrations run as a separate one-off `db-admin` task with its own execution role, which the API's role cannot read | `env/db_admin.tf`; batch B #781. Live once the schema phase has run db-admin (box 7 evidence) |
| A database dump revealing a child's words | Excerpts are encrypted by the API with `VAULT_KEY` before they reach the database | `src/lib/snippetVault.ts`; `test/content.test.ts` |
| Something inside the VPC answering as the database | The API checks the database's certificate chain and hostname, and refuses to start on a URL that would not | `src/lib/databaseTls.ts`, `scripts/check-db-tls.mjs` (#777); `rds.force_ssl` (#766 9) |
| Reading cache traffic, or writing to the cache from inside the VPC | Redis TLS (`rediss://`), and an AUTH token written out of band | `test/redis-url-tls.test.ts`; `elasticache.tf` (`transit_encryption_enabled`, `auth_token`); `production_guard.tf` requires both |
| Plain HTTP between the ALB and the task | Inside the VPC; the task's security group admits port 3000 only from the ALB's. TLS ends at the ALB. **Proposed for acceptance for the closed beta only**, with HTTPS to the task before public launch | `env/network.tf` (`api_from_alb`); `infra/terraform/README.md` ("Load balancer to task"). Needs Ahmed's and Karim's written acceptance on #637 (§5) |
| Losing the database | Multi-AZ, 14 days of point-in-time restore, deletion protection, a final snapshot; a daily AWS Backup copy to a locked vault in another account and region (`eu-west-1`), which the production account cannot delete | `rds.tf`, `env/production_guard.tf`, `env/backup.tf`, `org-audit/backup_vault.tf`; batch D #783. One restore drill: `restore-drill.sh`, log due on #637 (box 7) |
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
| Compromised code in a task sending data anywhere | The task can leave the VPC only on port 443; inside the VPC it reaches only PostgreSQL (5432) and Redis (6379), each by security group. 443 is still open to any address, so this limits the channel, not the destination. Accepted for the closed beta; **revisit before public launch** with an egress allowlist (VPC endpoints plus the APNs and FCM hosts) | `env/network.tf` (`api_https`, `api_to_rds`, `api_to_redis`); #766 item 6 |

### 4.8 Operating the account (T7)

| Threat | Control | Check |
|---|---|---|
| Destroying production by mistake | `down.sh` refuses production; RDS and the ALB carry deletion protection; `up.sh` only applies a plan file that was saved and read | `infra/terraform/down.sh`, `up.sh`; `env/production_guard.tf` |
| Running production with the staging credential, or the reverse | `up.sh` requires a named profile for production and refuses the staging one; the provider pins the account id | #772; `backend/*.hcl` |
| Production created without its protections | Both stacks refuse to plan production unless every protection is set | `*/production_guard.tf`; `*/tests/environments.tftest.hcl` |
| Secrets readable from Terraform state | Production secrets are written out of band, so state holds no secret values; the state bucket is versioned, encrypted with a customer key, TLS-only, and its policy is limited to the deploy role | batch B #781 (applied 15 Nov; secrets rotated after, new `INTERNAL_HMAC_SECRET` fingerprint on #637) |
| A misused deploy credential | Owner decision of 2026-11-14 (#637 comment 6881338157): Karim signs in through Identity Center with MFA; Claude and Kimi keep one permanent, full-rights machine credential on his PC. That is a written exception to "no long-lived keys", accepted by the owner, with Ahmed's six compensating controls (#637 comment 6881460052): no erasing evidence or backups (deny policies, and an SCP in production); no self-escalation (own keys only, a boundary on every role it creates, no new identity providers); a key-age rule at 100 days; the key in the PC's credential store; an alarm (not a deny) on use from elsewhere; root with MFA and no keys | `org-audit/agent_guardrails.tf`, `role_boundary.tf`, `access.tf`, `identity_center.tf`; batches E and F (#784, #793), applied 15 Nov (F3 20:54 UAE). Refused-call evidence: #637 comment 6898743142. osra-security#27 |
| An action nobody can reconstruct afterwards | An organisation CloudTrail whose bucket sits outside the production account under S3 Object Lock (365 days); GuardDuty in both regions; VPC flow logs, WAF logs (the authorization and cookie headers, the device signature header and the whole query string redacted) and PostgreSQL logs, 90 days; the alarm topic encrypted with its own key. **ALB access logs are off on purpose**: they record the full query string, where a WebSocket ticket or a reset token travels, and the WAF's redacted log covers the same requests | `org-audit/main.tf` (`trail_retention_days`), `guardduty.tf`; `env/audit_logs.tf`, `env/ecs.tf` (comment above the ALB), `env/alarms.tf` (`aws_kms_key.alarms`); batch C #782 |

## 5. Open items for this gate

Each is tracked where its detail may be written. This page gives the number only.

| Item | State on 2026-11-18 | Needed for sign-off |
|---|---|---|
| osra-security#27 (who can deploy to production, and how) | Decided by Karim 2026-11-14; batches E and F applied 15 Nov; refused-call evidence on #637. **Accepted residuals, not done:** the 22 Oct key is still the effective production key, and the follow-ups (retire it, split plan from apply, and the rest of Fable's list) are still open | Ahmed reads the evidence and closes it, with the residuals listed |
| osra-security#14 (device secret at rest) | Fixed by #839 (merged 16 Nov) | After the service phase: a count of device rows still stored the old way, expected to fall to 0 (row 7) |
| osra-security#15 (billing) | **Accepted by Karim for the beta**, 16 Nov (#637 comment 6909499225); fix before paid launch | None for the beta |
| osra-security#20 (an SOS's place in alert data) | **Closed** (fixed by #743, `1864f1bb`) | Done |
| osra-security#26 | Closed | Done |
| osra-security#32 | **Closed** | Done |
| #789 (mailed links opened no page) | Merged 15 Nov (#804) with both Bureaus' lines | Done |
| Push (APNs and FCM) in the production task | **Required by Karim** for the first testers (16 Nov); wiring merged (#840); the empty APNs secret applied 17 Nov | Box 3 launch run at exit 0 with the four `PLAY_*` values listed as Karim's accepted exception |
| Plain HTTP from the ALB to the task (#766 item 4) | **Accepted for the closed beta only** by Ahmed (#637 comment 6950396150) and Karim (17 Nov 19:13 UAE, #637 comment 6952130548), on four conditions: private subnets with no public IP, task ingress from the ALB's security group only, TLS on that hop before any public launch (public-launch-gate issue), and this written acceptance | The service-phase plan shows the first two conditions |
| Backup lifetime against the privacy notice (§6) | **Decided: 14 days everywhere** (#906 merged): the AWS Backup plan, and up.sh's pre-migration backup as an AWS Backup job with `DeleteAfterDays: 14` | Row 6 evidence as deployed |
| Backup location against the privacy notice (§6) | **Decided by Karim 18 Nov: Frankfurt only.** The copy to the `eu-west-1` vault is turned off (#907) and the notice is unchanged | Row 6 evidence that the deployed plan has no copy action |
| Restore drill (#766 item 5) | Script merged; first recovery point taken | Drill log on #637 |
| #766 items 1 to 13 | Batches A to F merged and applied 15 Nov; base apply for push 17 Nov; schema phase (db-admin, migrate) and service phase still to run | Applied before the service phase is signed |
| #777, #778, #772, #767 | Merged | Done |

Not in the candidate `0036d6b9`, so not in this pass: #760's ring routes and the `child_dismissed` cap, and #884's boot report. They belong to the next server candidate's pass.

## 6. What the configuration must match in the published privacy policy

`site/privacy/index.html` makes these promises. A setting that breaks one is a finding for box 6 of the gate.

| Promise | Setting that keeps it |
|---|---|
| Location history: 30 days | `LOCATION_RETENTION_DAYS` unset (default 30) or at most 30 |
| Activity events and stored message excerpts: 90 days | `RETENTION_DAYS` unset or at most 90 |
| Daily app-use totals: 365 days | `ROLLUP_RETENTION_DAYS` unset (default 365). The code accepts a larger number, so production must leave it unset or at most 365; `check-production-taskdef.mjs` fails a larger value |
| Alerts: 12 months, or until the child or the account is deleted | `ALERT_RETENTION_DAYS` unset (default 365); the code caps it at 365 (`src/lib/usageModel.ts`) and `check-production-taskdef.mjs` fails a larger value |
| Records of a reset of two-step sign-in: 12 months after the reset ends | The nightly job in `src/jobs/mfaResetExpiry.ts`; `test/mfa-reset-expiry.test.ts`. No setting changes it |
| "Data deleted from our live systems can remain in a backup until that backup expires, 14 days later" (section 11) | Point-in-time restore is 14 days and keeps the promise. **It is broken today by the AWS Backup plan** (`env/backup.tf`: 30 days in the account, 90 days in the copy vault) and by the named snapshots `up.sh` takes before each migration, which never expire. Fix before the first family's data: either both lifecycles at 14 days and named snapshots deleted after 14 days, or a reviewed change to the notice (owner's decision, through the Arabic Language Bureau for the Arabic text) |
| Installed-app list: kept for app rules and new-install alerts, replaced with each report and deleted when the device is removed | `src/routes/devices.ts` (the installed-apps write is a replace, not a merge; its `DeviceApp` rows cascade when unpairing deletes the device) |
| Deleting an account: the creator's deletion removes the whole family and every child's data; an invited parent's removes only their own account | `src/routes/account.ts`; `test/account-deletion.test.ts` |
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
