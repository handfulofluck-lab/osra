# ADR-0044: Parent feedback on flagged messages

Status: accepted

## Context

Parents need a way to mark an AI-flagged social message as concerning or not concerning so the evaluation set reflects their judgement. The vote is attached to a child's private message, so its storage, deletion and export rules matter as much as the buttons. The UI/UX and Arabic Language Bureaus defined the controls and copy; Ahmed defined the privacy conditions on issue #1065.

ADR-0013 deliberately left `SocialEvent` without a child foreign key and made child erasure explicit and countable. This change needs feedback to disappear on every existing deletion path without weakening that record.

## Decision

1. Each parent has one current vote per social event, stored in `SocialEventFeedback` with the voter's display name, first and last change times and change count. `POST /v1/social/events/:id/feedback` creates or changes it; `DELETE` withdraws it. Repeating the same verdict is a no-op, and withdrawal is idempotent.
2. The feedback row references both the social event and parent with `ON DELETE CASCADE`. `SocialEvent` now references its child with `ON DELETE CASCADE`; existing explicit child/family erasure remains in place and countable. Retention deletes the event and therefore its votes.
3. The vote stores only the verdict and nullable flag-time model fields: version, language, top category/score, cutoff, decision path and severity. It never copies message text. No vote goes to logs, Redis, push payloads or analytics.
4. `GET /v1/social/events` returns only the latest vote and voter name for co-parents. Writes require a parent session, the `social` permission and family ownership of the event.
5. Aggregation for evaluation is counts-only by language, category, model version and path. Buckets with fewer than five current votes are suppressed; withdrawn votes vanish on the next read.
6. The Parent app uses the Bureau's text buttons rather than thumbs. Votes are optimistic, changeable and withdrawable, with saving and retry states. SOS and location alerts do not offer voting.

## Reasoning

A per-parent unique key lets co-parents keep independent votes while the latest change explains who made it. Cascading from the existing vault event avoids a second retention policy and makes deletion tests meaningful. Counts-only aggregation limits re-identification risk and avoids shipping ids or content into an evaluation pipeline.

The new child foreign key makes direct message deletion atomic with its votes; the existing explicit erasure functions still document and measure the larger family cleanup rather than being replaced by an invisible database-side shortcut.

## Alternatives considered

- **A single vote per event:** rejected because a second parent would overwrite the first parent's judgement without an audit trail.
- **A separate feedback datastore or Redis cache:** rejected because votes would outlive the vault row and leak into exports or push paths.
- **Thumbs up/down icons:** rejected by the UI/UX Bureau because approval of a harmful message is culturally ambiguous; text labels name the judgement.
- **Keeping every historical vote:** rejected because withdrawal must remove the vote from later exports, not merely hide it in the app.

## Consequences and costs

- Migration `0043_social_event_feedback` adds a foreign key to an existing table; deploy must run before the new Prisma client serves requests.
- Older events have null model metadata. That is honest, not a fabricated model version or cutoff. Provider cutoff remains null unless the provider reports it.
- Optimistic UI can briefly differ from another parent's later vote; the next event refresh reconciles it, and failed writes remain marked for retry.
- Aggregation is for reviewed flagged alerts only. It cannot measure messages the model failed to flag, so it must not be presented as a miss rate.

## Evidence

- Focused API tests prove wrong-family and guardian-permission refusal, create/change/replay/withdraw, model snapshots, latest-voter mapping, sub-five aggregate suppression, and deletion through message, child, family and retention paths.
- Full API: 1,391 passed, 10 skipped. Full Parent: 1,255 passed, 1 skipped. Focused Flutter tests cover the three states, optimistic retry, and 320 px at 200% in English and Arabic.
