### CI — a merge to main is never cancelled, so its iOS build is never skipped (roadmap 3.9)
- `parent-app.yml` gives each push to `main` its own concurrency group. The iOS scope check decides from
  that push's own diff, so when the merge of #354 cancelled the run for #362's merge, #362's change to
  this workflow (an iOS input) was never built on `main` until the nightly run. Pull requests still cancel
  older runs, because each run there diffs the whole PR against its base.
