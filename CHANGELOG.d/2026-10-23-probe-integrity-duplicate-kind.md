### Tooling — a check that is also a target is no longer reported as its own demotion (#340)
- **The defect:** `check-probe-integrity.mjs` flagged `DEMOTED check -> target` whenever a title appeared as
  a `check` in the base and as a `target` in the head — **even when it was still a `check` in the head too**.
  A probe that writes
  `if (precondition) check("Q6 …"); else target("Q6 …");`
  puts one title in both kinds by design, so the pass read its own target line as a demotion of its own check
  line. **`main` failed against itself:** `--base origin/main --head HEAD` on `origin/main` reported two
  demotions, which is how it was found — #336 and #339 sat red for changes that touch no probe at all.
- **The fix, and the correction to my first attempt.** A demotion is skipped only when the fallback was **already
  there** (`b.found.check.has(name) && a.found[weaker].has(name)`), not merely because a check survives. My first
  version skipped any name that still had a check, which made the gate narrower in a different way: a check could
  **gain** a same-name advisory fallback with no acknowledgement, where before that needed an entry in
  `scripts/probe-gate-acks.json`. Claude measured it against a wrapped `G3` and caught it — AGENTS.md §4 says a gate
  may be extended, not narrowed, and an over-permissive fix breaks that rule as surely as a false positive does.
- **A fixture for the pattern:** base and head both carrying the if/else title produce no finding. Mutant measured —
  remove the guard and it fails with `DEMOTED check -> target: Q6 same title` (16/17); restored, 17/17. With the two
  review fixtures the suite is **17 cases**, so the numbers in the earlier revision of this fragment (14/15, 15/15)
  were the 15-case suite's — corrected here rather than left to read as the current counts.
- The promotion note also skips a title that was already a check, so it cannot print "promoted" and "demoted" for
  the same name in one run — which is what the broken run did, and what made it obviously wrong on reading.

- **A canary, because this class is otherwise invisible on the day it lands.** `ci.yml` now runs the gate with
  `--base HEAD --head HEAD` — the same tree against itself — which must report nothing. **Measured: the old script
  exits 1 with two `DEMOTED` lines on an unchanged tree; the fixed one exits 0.** One line in CI would have caught this
  when the if/else pattern was introduced instead of on the next PR that happened to be open.
- **Two related facts worth recording.** (1) `probe-integrity` is gated on `github.event_name == 'pull_request'`, so it
  does not run on pushes to `main`; a probe regression that lands is only seen by the *next* PR, which is then blamed for
  it. The canary above is what closes that gap without changing the trigger. (2) The pattern arrived via a PR whose own
  run saw only "added" (the title was new), which is why the introducing PR was green and every later one was red — the
  asymmetry only appears once both sides carry the duplicate.
