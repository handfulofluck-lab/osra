# ADR-0028 — Production hosting: managed containers on AWS, one independent stack per region, push-first devices

**Status:** accepted (Karim confirmed AWS and the budget on 2026-10-21 06:04Z)
**Date:** 2026-10-20
**Deciders:** Claude (architecture); launch order of markets decided by Karim on 2026-10-20
**Full analysis:** the "OSRA Backend Architecture, Hosting and Cost" document in the OSRA project
(cost model per component at 1k / 10k / 100k / 1M families, sources and assumptions)

## Context

- There is no production or HTTPS staging hosting. `infra/k8s`, `infra/terraform` and `infra/docker`
  are empty; everything runs from `docker-compose.yml` (API, PostgreSQL 16, Redis 7, AI engine) on the
  maintainer's PC (ADR-0018). Release builds refuse cleartext, so release-build rows (for example
  TR-73) wait on an HTTPS server.
- The API is already a stateless container: PostgreSQL is the source of truth (ADR-0012, ADR-0013),
  Redis is used for fan-out, tickets, revocation flags and caches.
- Launch order (Karim, 2026-10-20): **Middle East first, then Asia, Europe and the Americas.**
- Measured from the code on `main` (`3cc2212`), one Android child phone with the protection service
  running sends about **3 requests a minute (~4,400 a day)**: a command poll every 60 s
  (`LocationService.kt:478`), a live-activity heartbeat every 60 s, a location flush every 60 s
  (fixes every 5 min still / 30 s moving, `LocationService.kt:474-477`), plus telemetry every 15 min
  (`WorkScheduler.kt`). The Windows agent polls rules every 60 s (`RuleSyncService.cs:9`). Child
  devices, not parents, set the backend's size.
- iOS does not let an app run a 60-second loop in the background, so the iPhone agent cannot use the
  polling model at all; it needs APNs wake-ups.

## Decision

1. **Hosting model: managed containers + managed database on AWS.** API on ECS Fargate (ARM,
   autoscaled on CPU and request count, minimum 2 copies), PostgreSQL on Amazon RDS with a standby in
   a second availability zone (Aurora is an option later), Redis as ElastiCache Valkey, email through
   SES, secrets and `VAULT_KEY` in KMS / Secrets Manager. GCP (Cloud Run + Cloud SQL) is an equivalent
   fallback; nothing in the code is AWS-specific.
2. **One complete, independent stack per region; a family lives in exactly one region**, routed by
   `Family.region`. No cross-region database. Default regions, opened only when that market launches:

   | Order | Market | AWS region | Note |
   |---|---|---|---|
   | 1 | Middle East | UAE `me-central-1` | Serves Saudi Arabia too: in-country storage applies to companies operating inside the kingdom (Karim, 2026-10-20); revisit if OSRA sets up a company there |
   | 2 | Asia | Singapore `ap-southeast-1` | Mumbai `ap-south-1` if India is the main Asian market |
   | 3 | Europe | Frankfurt `eu-central-1` | GDPR |
   | 4 | Americas | N. Virginia `us-east-1` | COPPA |

3. **Devices become push-first before public launch.** A command or rule change is still written to
   the durable queue (ADR-0012, unchanged), then the server wakes the device through FCM (Android),
   APNs (iOS) or a frame on the desktop agent's open connection. Polling stays only as a 15-minute
   safety net. The live-activity heartbeat runs only while a parent has that child open. Location is
   batched every 5 minutes with a distance filter. Target: about **430 requests per child device per
   day** (ten times fewer).
4. **Each device reports a capability list** (platform, build flavour, and what it can enforce or
   report) and **every client sends its app version**; the server keeps old request shapes working for
   at least two releases and can answer "update required". This is how mixed Android / iPhone / Windows
   families get honest screens, and how an app stuck in store review keeps working.
5. **Location retention drops to 30 days** (confirmed by Karim as a product decision, 2026-10-20 17:28Z);
   other raw data stays at 90 days, rollups at 365 (ADR-0013
   otherwise unchanged).
6. **Growth steps, taken when traffic calls for them, not before:**
   - ~10k families: background jobs move out of the API process into a worker; the realtime gateway
     subscribes per family instead of `family:*:events` on every copy; `LocationPing`, `WebVisit` and
     `ActivityEvent` are partitioned by month (retention drops a partition instead of `deleteMany`);
     a read replica for parent dashboards.
   - ~100k: savings plans; the AI classifier on its own autoscaled service; history older than 30 days
     to cheap storage; the second region when its market opens.
   - ~1M and beyond: families split across several databases by family id through a small lookup
     table; more regions as markets open; the busiest paths (location ingestion, alerts) become their
     own services behind a queue; managed Kubernetes (EKS Auto Mode) only if Fargate starts to limit
     us. Every step is infrastructure as code (Terraform from day one), run by the agents with paging
     alerts; no dedicated hire is assumed, and no step changes the device apps.
7. **Service targets at launch:** 99.9% monthly uptime, a parent's lock/ring reaches the phone in 5 s,
   a concern alert reaches the parent within 1 minute, a public status page, and one restore-from-backup
   drill before launch.

## Reasoning

- Managed containers run today's Docker images unchanged and take database failover, backups and
  patching off a team that has no operations engineer. The extra cost over rented servers is small next
  to one lost night of a child-safety service.
- AWS has a region in the UAE for the first market, Asia, Europe and US regions for the later ones,
  and every managed piece the stack needs (PostgreSQL, Valkey, email, keys).
- Independent regional stacks keep each family's data in its own jurisdiction with no replication
  logic, and an outage in one region does not touch another.
- Polling, not product features, is what stops the cost curve from bending: at 1M families today's
  cadence is about 100,000 requests a second, mostly "anything new?" with an empty answer. Push-first is
  needed for iOS regardless, so doing it for every platform gives one wake-up path to test.

## Cost estimate (US$ a month, on-demand AWS list prices, recommended design)

| Families | Total | Per family |
|---|---|---|
| 1,000 | ~$430 | $0.43 |
| 10,000 | ~$1,200 | $0.12 |
| 100,000 | ~$5,700 | $0.057 |
| 1,000,000 | ~$40,500 | $0.040 |

Includes API servers, PostgreSQL with standby and storage, Valkey, load balancer, data transfer, digest
email, the AI classifier and DeepSeek V4.1 Flash calls for 5% of Full-build scans, monitoring, staging
and backups. Excludes salaries and on-call. With today's polling the same model gives ~$1,850 at 10k
and ~$18,300 at 100k, and needs a sharded database from about 100k families. Gulf and Asian regions
run roughly 10–20% above US prices (inferred). Each new region costs its fixed minimum (~$400) from the
day it opens. These are estimates from a model, not quotes; the per-component table and sources are in
the full analysis.

## Alternatives considered

- **Kubernetes (EKS / GKE) from day one.** Same containers, more control. Fargate already automates
  what Kubernetes automates for us (restarts, scaling, rolling deploys) without a cluster to upgrade.
  Rejected until Fargate limits us; then managed (EKS Auto Mode), not a self-run cluster.
- **Build for more than 1M families from day one** (sharded databases, multi-region from launch).
  Rejected: roughly $3,000–5,000 a month with no users (estimate), every feature pays the sharding
  complexity before launch, and real traffic must show which path strains first. Kept cheap instead:
  data keyed by family, stateless API, independent regions, infrastructure as code.
- **Serverless functions for the API.** The parent WebSocket and the Prisma connection pool want
  long-lived processes. Rejected for the API; acceptable for side jobs.
- **Rented servers (Hetzner, OVH) with self-run PostgreSQL.** 2–4× cheaper compute, but we would own
  failover, backups and patching, and there is no Gulf region. Kept for test labs only.
- **PaaS (Render, Railway, Fly).** Fast start, weaker data-residency story for children's data.
  Acceptable for a first HTTPS staging server only.
- **One global database with regional read copies.** Rejected: puts every family's data under every
  jurisdiction's question and adds replication logic for no product benefit.
- **Keep polling and scale the database instead.** Rejected: cost per family stops falling at ~10k
  families, and iOS cannot poll anyway.

## Consequences

**Good.** Cost per family falls with scale; regions open independently in launch order; the product
rules in ADR-0002/0003/0006/0008/0012/0013 are untouched; release-build rows get an HTTPS server.

**Bad, and accepted.** A cloud bill from the first day (~$150 a month for staging, ~$430 at 1k
families); push-first adds a dependency on FCM / APNs delivery, so the 15-minute safety poll stays; the
capability list and version gate are new contract surface to keep in `packages/shared-types`; shorter
location history is a visible product change that the privacy policy must state; the 30-day
window is a product decision, confirmed by Karim on 2026-10-20 (30 days chosen over 90).

## Falsifiable claims a verifier can test

1. On `main` today an Android child phone with the service running makes ≥ 3 API requests a minute
   while idle (count requests per device in the API log over 10 minutes).
2. After the push-first change, the same phone idle for 10 minutes with no parent watching makes ≤ 3
   requests in total, and a parent's `lock` still reaches it within 5 s (FCM) with the command row
   moving `pending → delivered → acked`.
3. With FCM blocked, a queued command is still delivered within 15 minutes by the safety poll.
4. A family created with a Middle East region is stored only in the UAE stack's database.
