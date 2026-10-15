# ADR-0005 — A separate adversarial probe suite is the merge gate

- **Status:** accepted
- **Date:** 2026-10-11
- **Supersedes:** —

## Context

Before this decision the repo had 193 API unit tests, a 50-check live end-to-end suite, four platform
test suites — **all green** — while the product had, in production terms, critical holes:

- per-device HMAC secrets were returned to parents and to any device (found only by trying the "wrong"
  request by hand);
- a device could write alerts into a *sibling* child's timeline;
- device revocation only applied to one route prefix;
- four alert categories the agents actually send were rejected with `400` and silently dropped;
- the iOS agent's alert shape was rejected `401` (the whole pipeline dead).

Every one of those defects was invisible to the suites because the suites assert the behaviour we
*intended*: they log in correctly, send well-formed payloads, use the same family, and check the happy
path. Green tests were being read as "the security contract holds".

## Decision

Maintain a **separate adversarial suite**, `services/api/scripts/qa-probe.mjs`, whose purpose is to
**break** the documented invariants rather than confirm the features. It:

- is organised by invariant, not by feature (auth, isolation, consent, device identity/revocation, token
  hygiene, alert coverage, input bounds, error hygiene);
- asserts the *rejection* (`403`, `401`, `400`, `428`) and prints the observed status on failure;
- runs against a live stack (Postgres + Redis + API), because half the defects were in wiring, not in pure
  functions;
- exits non-zero while any check fails, so it can be a gate;
- distinguishes three severities of outcome:
  - **failures** — must be fixed to make the gate green (a real invariant is broken);
  - **targets** — tracked behaviour that needs a product/design decision before it can be asserted
    (e.g. replay protection, consent revocation); reported but non-gating, so the gate stays actionable;
  - **notes** — observations for the record (e.g. a destructive-drain route a parent can call).

The collaboration protocol (`AGENTS.md`) makes it the merge gate: an item is done when its named probe
checks flip from FAIL to PASS **and nothing else regresses**.

## Reasoning

- Tests written by the author of a feature inherit the author's assumptions. A deliberately adversarial
  suite starts from the invariant and asks "what would break this?", which is a different question.
- Running against a live stack catches wiring defects (middleware mounted in the wrong scope, secrets
  returned by a serializer, a route missing the ownership assertion) that unit tests with mocks
  structurally cannot see.
- Separating *failures* from *targets* keeps the gate honest: a gate that can never go green gets
  ignored, and a target that is silently green hides an undecided question.
- The suite is also the fastest way to re-verify after someone else's change: it is ~70 checks in
  seconds, versus minutes for the platform suites.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Add more unit tests in the same style | Same blind spot; the author's assumptions would be encoded again |
| Rely on manual penetration testing per release | Not repeatable, not in CI, and the findings expire the moment the code moves |
| Make every check a hard failure | The gate would have been red for undecided design questions (replay, consent revocation), which trains people to ignore it |
| Use an off-the-shelf scanner | Useful for generic issues, but the invariants here are product-specific (family isolation, per-device identity, consent) |

## Consequences

- **Positive:** the 19 failures from the first run are now all green and each is a permanent regression
  check; the suite caught the `#29` class re-appearing in brand-new routes within hours.
- **Negative:** the probe needs a live stack and secrets, so it is not the first thing that runs in CI
  (unit tests are); it is also a file two agents edit, which is why additions must not weaken existing
  checks (enforced by review, and by the `AGENTS.md` rule).
- **Consequence for authors:** adding a route means adding the corresponding adversarial check; the probe
  growing is expected, and a PR that adds a route without a check will be sent back.

## Evidence

- `services/api/scripts/qa-probe.mjs`; run instructions and current state in `docs/TESTING.md`.
- The first full run (49 passed / 19 failed / 2 targets) and its aftermath are recorded in
  `docs/QA/QA-REPORT-2026-10-11.md`, `docs/QA/ANTIGRAVITY-INBOX.md` and `docs/QA/DISCUSSION-LOG.md`.
