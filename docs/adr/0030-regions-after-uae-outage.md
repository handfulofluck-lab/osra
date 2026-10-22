# ADR-0030 — Regions after the AWS UAE outage: production in Frankfurt, staging in Stockholm

**Status:** accepted (Karim chose Frankfurt on 2026-10-22 17:31Z)
**Date:** 2026-10-22
**Deciders:** Claude (architecture); the production region chosen by Karim
**Supersedes:** the region table and region order in ADR-0028 decision 2. Everything else in ADR-0028 stands.

## Context

- ADR-0028 put the first production stack in AWS UAE (`me-central-1`). That choice was made without
  checking the region's current state.
- In March 2026, drone strikes damaged AWS facilities in the UAE and Bahrain. In September 2026, AWS said
  data held only in `mec1-az2` can no longer be made accessible. `mec1-az1` and `mec1-az3` are still being
  recovered, with "more clarity in the coming months", and AWS has advised customers to move workloads to
  other regions. Bahrain (`me-south-1`) is written off. Sources:
  [Techzine, 2026-09-16](https://www.techzine.eu/news/infrastructure/144322/aws-cant-recover-all-data-from-data-centers-hit-in-middle-east/),
  [Insurance Journal, 2026-09-16](https://www.insurancejournal.com/news/international/2026/09/16/885283.htm).
- Our account saw it first-hand on 2026-10-22 (#258):
  - ECR in `me-central-1` refuses image pushes ("Image push is not available in this region"), while the
    same image pushes to `eu-north-1`.
  - The ElastiCache engine lookup returned `InternalFailure` three times (`infra/terraform/env/elasticache.tf`).
  - The EC2 API still lists `me-central-1b`, which maps to `mec1-az2`, as available. A three-zone subnet
    layout would land in the lost zone.

## Decision

1. **Production's first region is Frankfurt (`eu-central-1`)** and serves the Middle East launch, Saudi
   Arabia included. Families' data is protected under EU law (GDPR). The Gulf is about 0.1 s away, which
   push-first devices and parent screens do not notice.
2. **Staging moves to Stockholm (`eu-north-1`)** now. It holds no family data. The staging key's guardrail
   already allows that region, so no root sign-in is needed. The move steps are on #258: destroy the
   `me-central-1` base, a new state bucket in `eu-north-1`, one PR for every hard-coded region, then
   apply base.
3. **Nothing is built in `me-central-1`** until AWS publishes a full recovery of the region. Revisit then,
   or if an in-country requirement appears.
4. **Region order, replacing ADR-0028's table:**

   | Order | Market | AWS region | Note |
   |---|---|---|---|
   | 1 | Middle East (incl. Saudi Arabia) | Frankfurt `eu-central-1` | GDPR; the Europe launch reuses this region |
   | 2 | Asia | Singapore `ap-southeast-1` | Mumbai `ap-south-1` if India is the main Asian market |
   | 3 | Europe | Frankfurt `eu-central-1` | already open; no new region |
   | 4 | Americas | N. Virginia `us-east-1` | COPPA |

5. Opening Frankfurt for production means adding `eu-central-1` to the account's region guardrails. That
   happens when production's member account is created (ADR-0028 decision 8), not on the staging key.

## Reasoning

- A child-safety service can't sit in a region whose provider is telling customers to leave it, and
  where one of three zones is gone with no recovery date.
- Frankfurt was already in the plan for Europe, so the Middle East launch opens no region that would
  otherwise go unused. EU law also gives parents a clear answer about where their children's data lives.
- Mumbai would cut the delay to about 0.04 s. But it puts families' data under India's law, and it adds a
  region Europe can't reuse. The delay difference isn't visible in this app.
- Stockholm for staging is the cheapest move now: no guardrail change and no family data. Staging's role
  is testing release builds over HTTPS, and nothing about it depends on being near users.

## Consequences

- **Cost:** about the same as ADR-0028's model. Frankfurt is priced close to the US regions, so the
  10–20% Gulf premium assumed there no longer applies.
- **Data residency:** UAE and Saudi users' data is stored in the EU. The privacy policy must say so.
  Saudi was already planned as cross-border (Karim, 2026-10-20).
- **Work:** the staging move on #258, and roadmap row 5.8's wording ("the UAE production stack") becomes
  "the Frankfurt production stack".

## Falsifiable claims a verifier can test

1. `aws ecr put-image` (or `docker push`) to a repository in `eu-north-1` succeeds with the staging key.
2. After the move, `terraform state list` for both stacks shows no resource whose ARN contains
   `me-central-1`, and the state bucket is in `eu-north-1`.
3. `aws ec2 describe-availability-zones --region me-central-1` still lists `me-central-1b`, which is why
   the "nothing in `me-central-1`" rule is a rule and not something the API enforces.
