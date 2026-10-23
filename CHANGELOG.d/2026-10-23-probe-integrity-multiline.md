### Tooling — the probe-integrity gate now sees a `check(` whose title wraps (#310)
- `scripts/check-probe-integrity.mjs` matched assertions line by line, and `\s*` cannot cross a newline.
  A call written as `check(` and then `  "A4 …"` on the next line was never seen: it counted as neither
  added nor removed, so renaming, weakening or deleting one of those passed the gate, and adding one
  printed "0 added". On `68dd367` the matcher saw **132 of 141** `check(`/`target(` call sites; nine were
  blind, including `A4` and the `J3` consent group.
- The scanner now walks the whole file and skips whitespace — including newlines — before the opening
  quote. Interpolation normalisation (`${…}` -> `<*>`), the added/removed/demoted semantics and the exit
  codes are unchanged; this is a blind-spot fix, not a redesign. `--stats` prints the per-kind call-site
  count so the gate's own coverage is measured, not inferred.
- `--selftest` (14 cases, run by `workflow-lint.yml` on every push and PR) pins an inline `check("…")`,
  a wrapped `check(\n "…"`, a wrapped `target(`, an interpolated title, the demotion path, and a deleted
  multi-line call that must be `REMOVED`. Stated mutant: the old per-line matcher — under it the deleted
  wrapped call produces no problem and the CLI exits `0`; measured **7/14** before the fix, **14/14**
  after. `--stats` measures **132 -> 141** call sites on `68dd367` (and **149 -> 158** on the current
  `origin/main`, which gained calls after the issue was filed).
- Verified by running the self-test and the tool over the real probe. The API suite was **not** run: this
  change touches a Node script and no API code, and this worktree has no `node_modules`.
