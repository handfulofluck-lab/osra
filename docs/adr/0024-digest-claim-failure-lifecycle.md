# ADR-0024 — A digest send claim outlives a permanent refusal, not a transient one

- **Status:** accepted
- **Date:** 2026-10-18
- **Deciders:** Kimi Code (development lead), resolving F1/F2 of the #93 review recorded in
  `docs/QA/VERIFICATION-LEDGER-2026-10-18.md` §3 item 1; the claim mechanism itself is ADR-0017's
- **Related:** ADR-0017 (the digest is due at the family's local hour), ADR-0020 (family timezone);
  #93, #101

## Context

ADR-0017 replaced the Redis `SET NX` digest claim with a `DigestSend(familyId, kind, period)` row whose
unique key is written **before** the email, so a restart, two API instances or a DST-repeated hour cannot
send twice. That mechanism has one failure path that was never designed, and the #93 review named two
defects in how failures leave the claim:

1. **F1 — a thrown send loses the period.** The provider refusal branch deletes the claim
   (`services/api/src/jobs/digestScheduler.ts:113-117` at `603a33d`), but the `catch` around
   `sendFamilyDigest` only logged (`:119-120`). The row stayed, every later tick's insert hit `P2002` and
   `continue`d, and the family got no digest that whole period — permanently, because the period key is
   the local date or ISO week.
2. **F2 — every refusal was treated as transient.** The same delete-and-retry ran for a provider 4xx
   that will never succeed for that address, so an invalid recipient cost one provider call every 15
   minutes until midnight (and up to 24 on a Sunday, when both kinds are due).

The ledger's read at `f2437a9` confirms both on `main`. Neither is a product decision the code had made;
both are a missing decision about the **lifecycle of a claim**.

## Decision

The claim row's lifecycle is: **claim → sent, or claim → released (retry), or claim → retired (terminal)**.

1. **A success** leaves the row as the record that the period was sent. Unchanged.
2. **A transient failure releases the claim.** The row is deleted, so the next 15-minute tick can insert
   it again and retry inside the same period. This covers a provider refusal the sender classifies as
   retryable, and **every thrown send** — a throw is unclassified, and one extra attempt is cheaper than
   a lost day.
3. **A permanent failure retires the claim.** The row stays and `DigestSend.failedReason` is set. The
   unique key then skips the period on every later tick, and the row itself says why the family got
   nothing. This is the terminal state; there is no un-retire path inside a period.
4. **The classification belongs to the sender, not the scheduler.** `EmailResult`'s failure variant
   carries `retryable: boolean`; `ResendEmailSender` maps 408, 429 and 5xx to `true` and every other 4xx
   to `false` (`services/api/src/lib/email/index.ts`). The scheduler no longer parses HTTP strings, and a
   future sender (SES, Postmark) makes the same declaration next to the code that knows the provider.
5. **No attempt counter.** Transient retries are already bounded by the period boundary — the worst case
   is one provider call per 15-minute tick until the local day (or week) rolls over — so a counter would
   buy a smaller number at the cost of a state machine: either it must survive the delete (a `state`
   column plus an atomic `updateMany` re-claim to keep two instances from retrying at once) or it must
   turn the claim into `claimed | waiting | sent | failed`, and every one of those states is a new way to
   send twice. The terminal state gives the property that actually matters (a permanent failure stops
   retrying) with one nullable column.

## Alternatives considered

- **Attempt counter with a terminal threshold (the review's other suggestion).** Rejected for the reason
  above: it requires the claim to be re-claimable *without* deleting it, which is a concurrency protocol
  (atomic update from `waiting` to `sending`, plus a stale-lock timeout for a process that dies between
  the two) and a larger surface than the bug it fixes. It also classifies by repetition — three failures
  — where the provider already tells us the difference.
- **Delete the claim on every failure and record failures elsewhere.** Rejected: two tables for one
  fact, and the terminal row would have to be reconciled against the claim to answer "did this family
  get its digest", which is exactly the question `DigestSend` answers today.
- **Retire on every failure (never retry).** Rejected: a provider 5xx or a rate limit is exactly the
  case where the next tick succeeds, and it would trade a 15-minute gap for a lost day.
- **Keep the throw path as it was and only add the terminal state.** Rejected: that is F1, the defect
  the ledger calls a live correctness bug — a thrown send would still lose the period.

## Consequences

**Good.** A thrown send can no longer cost a family its period; a permanent refusal stops after one call
and leaves a reason on the row; the retry/terminal split is stated where the provider knowledge lives.

**Bad, and accepted.**

- A **misclassified** permanent failure loses the day. The classifier is deliberately conservative (only
  non-408/429 4xx is permanent), and the log line names the reason so an operator can see it.
- A **deterministic** throw (a template bug, say) retries every 15 minutes for the rest of the period.
  Bounded and loud, but it is provider quota and log volume an attempt counter would have cut.
- A retired row is invisible to the parent app: there is still no "your digest failed" notification or
  metric, only the row and the log. Observability is a separate item.
- `DigestSend` gains a column, so the migration must be applied before this code runs. It is nullable and
  additive: an older binary never selects it, so a rolling deploy is safe.

## Evidence

`services/api/test/email.test.ts` (digest scheduler suite) drives the real `runDigestsDue` against an
in-memory stand-in for the unique key:

- *a thrown send releases the claim and the next tick retries the same period* — fails on `origin/main`
  (delete never called, second tick `attempted 0`);
- *a permanent provider refusal keeps the claim terminal and is not retried* — fails on `origin/main`
  (delete called, provider called again on the next tick);
- *a transient provider refusal releases the claim so the next tick retries*.

`services/api/test/digest-schedule.test.ts` pins the local-hour interpretation of `DIGEST_HOUR`
(03:00Z is 07:00 in Dubai and due at hour 7, 03:00 in UTC and not due) and the boot warning for the
deprecated `DIGEST_HOUR_UTC` name.
