<!--
  Every change to this repo reaches main through a PR (AGENTS.md §6).
  Fill every section. The restatement (1) is the most important line: write what you
  UNDERSTOOD the ask to be, in your own words, before describing what you did.
-->

## 1. Restatement — what I understood the ask to be

> "I understand the ask as: …"
> (If you are unsure about any part of it, say so here and stop before the diff matters.)

## 2. Item / issue

- Closes: #<issue>
- QA item: <P0-1 / AND-02 / …> from `docs/QA/ANTIGRAVITY-INBOX.md`
- Acceptance line copied verbatim from the inbox:

## 3. What changed and why

<!-- A user-visible change needs CHANGELOG.d/<date>-<slug>.md; see CHANGELOG.d/README.md -->

| File:line | Change | Why |
|---|---|---|
|  |  |  |

Anything **not** changed that a reader might expect to be changed, and why:

## 4. Gates I ran (paste raw output, not a summary)

- [ ] `pnpm --filter @familyshield/api test`
- [ ] `node scripts/qa-probe.mjs` — before: `… passed / … failed` → after: `… passed / … failed`
- [ ] `node scripts/e2e.mjs` — `…/50`
- [ ] platform suite(s) for what I touched (`flutter test` / `./gradlew testDebugUnitTest` / `dotnet test` / `pytest`)

```
<paste the probe summary block here>
```

## 5. What the reviewer must verify (falsifiable claims)

1. …
2. …

## 6. Open questions, assumptions, deliberately not done

- Assumption I made:
- Question for the reviewer:
- Not done (and why):
- Follow-up issues this should create:

## 7. Discussion

- [ ] I have read the reviewer's point-by-point reply
- [ ] Every point is answered with evidence (or explicitly deferred to the human with `needs-human`)
- [ ] Any change to my restatement in §1 is re-stated and agreed before merge
- [ ] `docs/QA/DISCUSSION-LOG.md` updated with this exchange
