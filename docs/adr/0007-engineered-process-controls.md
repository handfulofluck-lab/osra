# ADR-0007 — Process is engineered, not promised: hooks, lint gates, PR-only `main`, hardware verification

- **Status:** accepted
- **Date:** 2026-10-15
- **Supersedes:** —

## Context

Two agents (one implementing, one verifying) plus a human work in this repository. Every process failure
observed in practice had the same shape: **a rule that existed only as an intention**.

Concrete incidents, all within nine days:

| Incident | Cost |
|---|---|
| A QA commit was pushed straight to `main` before review ("we will discuss first" was an intention) | history rewritten to move it to a branch |
| The pre-push guard "verified" by piping sample input into the script — the real hook never ran (relative `core.hooksPath` resolves to nothing on Git for Windows) | a direct push to `main` succeeded twice |
| `ci.yml` contained a step with both `uses:` and `run:`; YAML parsers accept it, GitHub rejects the file, **zero jobs ran** | a day with no CI signal at all, and an unbuildable `main` merged behind a "all gates green" claim |
| The iOS job ended its test command with `\|\| echo "…"` | the job could not fail; its green was read as proof the iOS build worked |
| An agent verified an Android fix against **stale test XML** from four days earlier | an unbuildable tree passed a "gates green" review |
| A verification pass claimed a feature was fixed after observing a success that depended on state the normal user flow never produces (location service alive only because a manual `appops allow` had been set) | issue reopened with a correction |

The pattern: *the gate was believed rather than executed*, and *the report was trusted rather than
reproduced*.

## Decision

Make each control executable, and make its limits explicit in the repo:

1. **`main` is PR-only.** Enforced by `.githooks/pre-push` (installed by `scripts/install-git-hooks.sh`,
   verified by attempting a real push), detected server-side by `.github/workflows/main-guard.yml` for
   clones without the hook, and — now that the repository is public — backed by GitHub branch protection.
2. **A pull request is a discussion.** `.github/PULL_REQUEST_TEMPLATE.md` requires a **restatement of the
   ask in the author's own words** before describing the change, the raw gate output, and a list of
   *falsifiable* things the reviewer must check. Reviews answer point by point with evidence;
   disagreement beyond one exchange escalates to the human as `needs-human`.
3. **Gates must be able to fail.** `scripts/check-workflows.mjs --strict` rejects
   `|| echo` / `|| true` / `continue-on-error` in the workflows and runs in its own workflow file (so it
   survives a sibling workflow being invalid) and in the pre-push hook.
4. **A YAML file GitHub would reject is caught locally**, because that failure mode is uniquely silent:
   lint is not "style", it prevents *zero jobs running while the UI looks configured*.
5. **Hardware verification is a separate, explicit stage.** Server-side fixes are verified against a live
   stack; device behaviour is verified on a physical device by the verifying agent, with the evidence
   (logcat, HTTP status, DB row) pasted into the issue. "It compiled" is not verification.
6. **Every claim carries its scope.** Reports state what was verified, where, and what was not — including
   corrections when a previous conclusion turns out to have been narrowly true.

## Reasoning

- A control that is not executed is worse than no control, because it buys false confidence. Each item
  above was chosen because it failed *silently* at least once.
- Writing the limits next to the control (in `AGENTS.md`, in the workflow comments, in the ADR) is what
  prevents the next agent from "fixing" a deliberate workaround — e.g. re-adding `|| echo` to make a red
  job green.
- Requiring a restatement is the cheapest known defence against the most expensive failure mode observed:
  work that is technically excellent and answers the wrong question.
- Hardware verification exists because the highest-severity defects found so far (crash-loop on first
  run, location never starting, cross-family content write reachable from a real device) were invisible
  to every automated suite.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Trust convention and review, no hooks/lint | This is exactly what failed six times in nine days |
| Rely solely on GitHub branch protection | Unavailable on free private repos; and it cannot catch "the workflow file is invalid" or "the tests were stale" |
| Require a second human review for every change | Correct in spirit, impractical for a two-agent team; the reviewer role is filled by the other agent, with the human as the escalation path |
| Make every check a hard gate immediately | Would block merges on undecided design questions (`J2`/`J3`/`J6`), which trains people to bypass gates; they are tracked as targets instead |

## Consequences

- **Positive:** the failure modes above now surface in seconds locally or in CI, with a message that says
  what to do; the PR record shows *why* a change is believed correct; corrections are part of the record
  rather than private.
- **Negative:** more files to maintain (hook, lint, template, ADRs, changelog) and a small tax on every
  change; reviewers must actually run things rather than reading diffs.
- **Residual limits, stated honestly:** a clone can skip the hook (`--no-verify` or no install), a
  determined agent can still merge a red PR if the human allows it, and hardware verification requires a
  physically connected device — which is why `AGENTS.md` records the rule and `docs/TESTING.md` records
  the procedure.

## Evidence

- `AGENTS.md` §3 (definition of done), §6 (landing changes and enforcement limits), §7 (device hygiene).
- `.githooks/pre-push`, `scripts/install-git-hooks.sh`, `scripts/check-workflows.mjs`,
  `.github/workflows/{ci,ios-ci,main-guard,workflow-lint}.yml`.
- `.github/PULL_REQUEST_TEMPLATE.md`, `docs/QA/DISCUSSION-LOG.md`.
- Incident record: `CHANGELOG.md` (2026-10-13 and 2026-10-15 entries), issues `#16`, `#33`, `#37`.
