# ADR-0045: Parent feedback ownership, conflict writes and legacy migration

Status: accepted; supersedes ADR-0044 decision 4 by adding `ownFeedback` alongside family `latestFeedback`

## Context

ADR-0044 made votes independent per parent but initially returned only the family-latest vote. That leaves a caller unable to distinguish their own current vote from a co-parent's later decision. Review also found three edge cases: different verdicts racing the first write could collapse into one request, a local-only rule hit could inherit the model's category and score, and the new child foreign key could fail on legacy orphaned events. The feedback database integration test was not provisioned in CI.

## Decision

1. `GET /v1/social/events` returns both `ownFeedback`, the caller's current vote or null, and `latestFeedback`, the most recently changed vote in the family or null. Both use the same verdict, voter-display-name, timestamp and change-count shape.
2. A successful `POST` returns `feedback` for the caller plus `latestFeedback` after the mutation. `DELETE` returns `feedback: null` plus the remaining `latestFeedback`, or null when no votes remain. Same-verdict replay does not make the caller's row the latest unless it is already latest.
3. Vote writes use PostgreSQL `INSERT ... ON CONFLICT DO UPDATE ... WHERE verdict <> EXCLUDED.verdict`. A conflicting different verdict increments the change count and moves the last-change time atomically; an identical conflict returns the unchanged row. This applies both to first-write races and to concurrent changes of an existing vote, preserving the original flag-time metadata.
4. When local rules cause a flag while the model is unflagged, `path` is `rules`, `topCategory` is the local category and `topScore` is null. Model version, language and cutoff remain honest facts about the model's response.
5. Migration 0043 deletes only already-orphaned `SocialEvent` rows before adding the child foreign key. An orphan's child has already been deleted, so preserving its event or message evidence would violate erasure. Valid events, including events for children whose consent is paused or revoked, remain unchanged. The migration emits only the deleted-row count, never ids or message text.
6. CI creates `osra_feedback_1065` and sets `OSRA_FEEDBACK_DATABASE_URL` whenever database tests are required. The destructive integration suite is restricted to that exact loopback database. Production application of 0043 is allowed only in the approved post-snapshot apply window; this record authorizes no AWS operation.

## Reasoning

Own and latest are different facts: independence requires the first, while co-parent transparency requires the second. Conditional conflict handling is the only atomic rule that both preserves identical-request idempotency and applies a different racing verdict. A real 0042-to-0043 upgrade with an orphan is necessary because an empty-schema migration cannot exercise the legacy failure.

## Alternatives considered

- **Returning only latest:** rejected because it cannot represent the caller's own state.
- **Unconditional upsert update:** rejected because identical concurrent replays would increment the change count, while an empty update loses a different verdict.
- **Quarantining orphans or dropping the child FK:** rejected. Quarantine would retain a deleted child's message evidence; removing the FK would weaken the cascade guarantee. Only rows already orphaned by child deletion are removed.
- **Deriving flag-time category from the model after a local-only hit:** rejected because it attributes the decision to the wrong path.

## Consequences and costs

- Event reads include all current votes for the family's parents so own and latest can be selected in one query; families have few parents, so this remains bounded.
- Latest is read again after each mutation and can change between concurrent requests; each response is a point-in-time result, not a global ordering guarantee.
- Legacy orphan deletion is irreversible and limited to rows whose `Child` no longer exists. The migration reports a count only; production use still requires the approved post-snapshot apply window.
- The integration suite drops the public schema in `osra_feedback_1065` on every run and must never be pointed elsewhere.

## Evidence

- Focused route tests cover two parents with same and different verdicts, own/latest reads, replay, withdrawal, different-verdict races and local-rule precedence.
- The real database suite starts at 0042 with valid, consent-revoked and orphaned events. It verifies that only the orphan is deleted, no orphan table exists, the deletion NOTICE is count-only, deploy output contains no ids or message text, valid and consent-revoked events survive, and deleting a child cascades through its events to votes. It also races different first verdicts and verifies event-vote cascade deletion.
- CI provisions the dedicated database and required environment so these integration rows cannot silently skip.
