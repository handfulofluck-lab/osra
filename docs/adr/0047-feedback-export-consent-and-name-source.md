# ADR-0047: Consent at feedback export time and one parent-name source

Status: accepted (Claude and Ahmed approved the minimal design on #1113, 2026-11-25)

## Context

ADR-0044/0045 introduced per-parent votes on flagged messages and counts-only, small-bucket-suppressed aggregation. The aggregate read initially included votes regardless of the child's current processing consent, and each vote copied `Parent.displayName` into `SocialEventFeedback.parentName`. A later consent revocation could therefore leave a family's votes in the next export, and a parent rename could leave stale identity in parent-facing views. Evaluation or training use of votes is blocked until both are corrected.

## Decision

1. Aggregation first selects distinct candidate child IDs and family regions without deciding consent. It calls `checkActiveConsent(childId, familyRegion)` for each candidate **at export time** and passes only active child IDs to `socialEventFeedback.groupBy`. No candidate means no aggregate query and no bucket.
2. Parent-facing feedback reads include the existing `parent` relation and render `Parent.displayName`; they do not read a copied name. The vote write no longer accepts or updates a parent name.
3. Migration `0044_drop_social_feedback_parent_name` drops the copied column. The documented rollback can recreate a nullable column but cannot recover its old values.
4. Vote-write behavior, the five-vote minimum bucket, and the rule that no message text or vote IDs enter the aggregate remain unchanged.

## Reasoning

Consent is a current processing decision, not a property of the vote's creation time. Reusing the existing gate preserves revocation, expiry and family-jurisdiction behavior rather than creating a second rule that can drift. The relation already owns the parent's current name, so copying it adds stale data without adding information.

## Alternatives considered

- **Gate only when a vote is written:** rejected because votes cast before revocation would remain in later exports.
- **Repeat the consent conditions in the aggregate SQL:** rejected because it would omit or diverge from the shared jurisdiction and paused-processing semantics.
- **Keep the copied name but exclude it from export:** rejected because parent-facing stale names remain, and the copy has no unique value.

## Consequences

- Export performs one shared consent check per distinct candidate child. This is acceptable for the offline counts-only aggregation; a future high-volume job should batch that check without changing its semantics.
- Existing copied names are permanently discarded by the migration. Current names remain available through `Parent`, and no vote verdict or message content is deleted by 0044.
- Rollback restores only the column, not its historical values. Any rollback requiring the old NOT NULL shape also needs an explicit backfill decision.
- The aggregation remains stateless: each run reads current votes and current consent, with no ID carry-over or training-pool state introduced here.

## Evidence

- Fail-first: seven new consent/schema tests failed before implementation; the relation-read route test failed with the stale copied name before the join change.
- Focused social/privacy suites: 72 passed, 4 skipped before the database URL was supplied.
- Full API: 1,411 passed, 14 skipped; TypeScript build clean.
- Real loopback PostgreSQL migration/race/cascade suite: 4/4 passed. The migration starts from the previous schema and is safe with an empty feedback table.
- Independent cross-family verification and Ahmed's `Security-signoff:` remain required before merge; no AWS or production data was touched.
