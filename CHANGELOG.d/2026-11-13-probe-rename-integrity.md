### API — the probe-integrity gate verifies a rename's replacement exists (#660, #683)
- `scripts/check-probe-integrity.mjs` now honours an optional `renamedTo` on a rename
  acknowledgement in `scripts/probe-gate-acks.json`: the replacement must exist in the head at the
  same or higher severity (`check` ≥ `target` ≥ `note`), so a rename that demotes a gating check is
  refused, and a missing replacement is refused too.
- A rename-word reason — `label only`, `renamed`, `relabel` or `moved`, case-insensitively — must
  carry `renamedTo`; the existing rename acknowledgements (E4/J2, J5, J7, G19, Q6, Q6b, G25) are
  backfilled with the exact current names from `qa-probe.mjs`.
- Since #683 the checker also requires `renamedTo` when a removed assertion gains a same-kind
  assertion in the head regardless of reason wording — a retirement reason paired with an unrelated
  same-kind addition needs `renamedTo` too, or that addition must land in a separate diff. For a live
  ack the `renamedTo` must be newly added (absent from base) and unique across all acks (a global
  invariant), while historical acks whose names the diff did not remove keep passing.
- The gate's `--selftest` grows to 27 cases, adding rename+demote, same-severity, promote, missing
  replacement, unbound-ack, renamedTo-already-in-base, shared-renamedTo, same-kind-addition,
  lowercase cross-severity rename, and same-kind-only-trigger (a non-rename reason with no
  `renamedTo`) coverage.
