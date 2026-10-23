### Tooling — a check that is also a target is no longer reported as its own demotion (#340)
- **The defect:** `check-probe-integrity.mjs` flagged `DEMOTED check -> target` whenever a title appeared as
  a `check` in the base and as a `target` in the head — **even when it was still a `check` in the head too**.
  A probe that writes
  `if (precondition) check("Q6 …"); else target("Q6 …");`
  puts one title in both kinds by design, so the pass read its own target line as a demotion of its own check
  line. **`main` failed against itself:** `--base origin/main --head HEAD` on `origin/main` reported two
  demotions, which is how it was found — #336 and #339 sat red for changes that touch no probe at all.
- **The fix:** a demotion now requires the gating check to be **gone** from the head (`if (b.found.check.has(name))
  continue`), and likewise a target must be gone before `target -> note` counts. Real demotions are unchanged:
  delete the `check` and leave only the `target` and it still fails.
- **A fixture for the pattern:** base and head both carrying the if/else title produce no finding. Mutant measured —
  remove the guard and it fails with `DEMOTED check -> target: Q6 same title` (14/15); restored, 15/15.
- The promotion note also skips a title that was already a check, so it cannot print "promoted" and "demoted" for
  the same name in one run — which is what the broken run did, and what made it obviously wrong on reading.
