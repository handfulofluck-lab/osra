### CI — a gate against committed conflict markers, because a conflicted merge can be green
- On 2026-10-23 a `git merge`, `git add -A` and `git commit` were chained in one shell command. The merge
  conflicted, `add -A` staged the markers, the commit succeeded, and a pushed commit carried `<<<<<<<` in
  `docs/SPEC.md` and `docs/ROADMAP.md`. Every suite stayed green, because no test reads documentation; the
  reviewer's own `git grep` found it.
- `scripts/check-no-conflict-markers.mjs` fails a tree (or `--staged` index) containing a **pair** of marker
  lines — an opening `<<<<<<< ` and a closing `>>>>>>> `. A single line is not enough, because a lone
  `=======` is a legitimate Markdown setext underline and prose about merges quotes the markers.
- `--selftest` proves both directions: a real conflict pair fails, while a setext heading, prose naming the
  markers, and one marker line alone all pass (4/4 cases).
- Wired into `workflow-lint` beside the diff-scope self-test. `node scripts/check-workflows.mjs --strict` is
  clean with the new step.
