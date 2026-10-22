# ADR-0030 — Staging region, staging lifecycle, and where the production region question now sits

**Status:** proposed (2026-10-22). Supersedes: ADR-0028's *staging* clauses and its region choice for
staging; it does **not** supersede ADR-0028's hosting model, cost model, per-region independence or
push-first device design.
**Deciders:** Claude (architecture, recommendation on 2026-10-22 17:21Z on #258) · Kimi Code (development
lead, drafted this record) · **Karim decides the staging region and, separately, production's first region**
**Evidence:** #258 comments of 2026-10-22 16:59Z (the four-way ECR test), 17:13Z (the hosted zone) and
17:21Z (the region evidence and the recommendation)

## Context

1. **ADR-0028 chose `me-central-1` (UAE) for an in-country reason**: launch order was Middle East first, and
   in-country storage was part of that bet. That reasoning still stands for production.
2. **`me-central-1` cannot accept an image for this account.** Four tests on 2026-10-22 separate our
   configuration from the region: `docker login` succeeds, `GET /v2/` returns 200, and both
   `aws ecr put-image` and a raw manifest `PUT` as the AdministratorAccess deploy user return
   `Image push is not available in this region`; the same manifest bytes to `eu-north-1` reach normal
   validation. No repository policy and no registry policy exists, and the deployer guardrail simulates
   clean for the relevant actions.
3. **Claude's 17:21Z finding, which changes the shape of the problem.** The region is not merely
   provisioning: AWS's UAE region has had two of three availability zones impaired and one (`mec1-az2`, our
   `me-central-1b`) declared unrecoverable with data loss, with AWS advising customers to migrate. `mec1-az2`
   is still listed `available` by `describe-availability-zones`, so a three-AZ subnet or RDS layout lands in
   it silently.
   *Provenance:* those are Claude's citations on #258 (isdown, Computing, InfoQ, CloudNews), recorded here
   because they drive the decision. **I have not independently verified the incident reports**; I have
   verified the ECR symptom myself, four ways.
4. **Karim's two staging decisions, given on 2026-10-22:** staging is **on-demand** — applied before a
   release-signed run, destroyed after it — and **HTTP only** until near go-live, when he chooses between a
   paid certificate and Route 53. Both are already how `infra/terraform/up.sh` / `down.sh` and the
   `env`/`base` split behave; this ADR is where the decision is recorded, not where new machinery appears.

## Decision

1. **Staging leaves `me-central-1`.** The `base` stack stays in place until the replacement region is applied
   (19 resources, ~US$2/month, no NAT/ALB/RDS/ECS ever ran). Nothing new is applied or dispatched in
   `me-central-1` in the meantime, including the replication experiment.
2. **Claude's recommendation is `eu-north-1` for staging**, and it is the only other *build* region the
   deployer key's guardrail permits: `ProtectThisUser` stops the key editing its own policy, so any other
   region requires Karim's root sign-in. Staging holds no family data, which is what makes a region outside
   the UAE acceptable here while production's choice is untouched.
3. **The staging region is Karim's to confirm**, not ours to assume. Until he does, the staging work stops at
   a green image-publish path.
4. **Production's first region remains open and is a separate decision** (for example Frankfurt or Mumbai).
   It replaces part of ADR-0028 and should be recorded in its own ADR when made. ADR-0028's in-country
   argument is not weakened by anything here; what changed is that the specific region it named for staging
   is damaged.
5. **The lifecycle decisions are restated as binding**, not as current practice: on-demand apply/destroy, and
   HTTP until go-live.
6. **Left in place deliberately, and why:** the `eu-north-1` repository `osra-staging/api`, the registry
   replication rule `eu-north-1` → `me-central-1`, and the `eu-north-1` ARN added to
   `osra-staging-publish`'s inline policy. They cost nothing and hold no images. The policy edit is **drift**
   against Terraform and the next `base` apply reverts it; that is acceptable only because it is recorded
   here.

## Reasoning

- **Why move rather than wait.** "Retry tomorrow" was option 3 in the 16:59Z list, on the theory that this
  was opt-in provisioning lag. The 17:21Z evidence makes that theory the less likely one: a region that lost
  an availability zone with data loss and is telling customers to leave is not a staging target, and the ECR
  refusal fits a write restriction rather than a delay. A day spent waiting proves nothing either way.
- **Why not keep the image cross-region (option 2).** It stores the artifact outside the country while
  gaining nothing once staging itself moves: the image would follow the region.
- **Why the guardrail shapes the recommendation.** Not because `eu-north-1` is the best region on merit —
  it is the only one reachable without Karim's root sign-in, and the cost of involving root for a staging
  choice is higher than the latency difference.
- **Why the decisions are recorded even though the code already behaves this way.** A behaviour that only
  exists in a script is one refactor away from disappearing, and ADR-0028 currently reads as though staging
  lives in the UAE.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Keep staging in `me-central-1`, no image | No task can be started; every `env` apply would be pre-broken |
| Cross-region pull into `me-central-1` | Image leaves the country for no gain once staging moves; execution role needs ECR rights in a second region |
| Retry in a few days | The evidence points at damage, not lag; costs time and proves nothing |
| Move staging **and** production now | Production's region is a product/residency decision with a launch-order dependency, and Karim has not made it |
| Add a second AWS account or sign in as root to reach another region | Not needed for staging if `eu-north-1` is accepted, and root for a staging choice is a poor trade |

## Consequences

- **Good:** staging becomes reachable again without touching production's decision; the on-demand lifecycle
  keeps the bill near zero; the region question is recorded in one place instead of in a comment thread.
- **Bad, and accepted:** staging's latency from the Gulf is worse than the in-country option would have been,
  and the `base` stack must be destroyed and re-applied in the new region — including secrets, which are
  re-created rather than migrated.
- **Risk to watch:** if production later goes to `me-central-1` on availability grounds, it must not span
  `mec1-az2`; two-AZ layouts or an explicit AZ exclusion are required, and that belongs in the production ADR.
- **Cost:** the `me-central-1` `base` (~US$2/month) runs until it is destroyed; `env` remains at US$0 until a
  session is started.

## Falsifiable claims a verifier can test

1. Nothing is applied in `me-central-1`: `terraform -chdir=infra/terraform/env plan` there fails or is never
   run, and `aws ecs list-clusters --region me-central-1` returns no `osra-staging-api` cluster.
2. The only AWS resources in `me-central-1` are base's 19, and the only image repositories are the
   `me-central-1` one (empty) and the `eu-north-1` one (empty until the first publish).
3. `infra/terraform/up.sh` and `down.sh` implement the on-demand lifecycle and `env` creates no 443 listener
   without a certificate — the HTTP-until-go-live decision, already testable by plan.
4. The drift claim is true: `base`'s publish role policy in Terraform does not name the `eu-north-1` ARN, so a
   `base` apply would remove that statement.
