### API — the probe-integrity gate verifies a rename's replacement exists (#660)
- `scripts/check-probe-integrity.mjs` now honours an optional `renamedTo` on a rename
  acknowledgement in `scripts/probe-gate-acks.json`: the replacement must exist in the head at the
  same or higher severity (`check` ≥ `target` ≥ `note`), so a rename that demotes a gating check is
  refused, and a missing replacement is refused too.
- A reason starting `Label only` or `Renamed` must carry `renamedTo`; the existing rename
  acknowledgements (E4/J2, J5, J7, G19, Q6, Q6b, G25) are backfilled with the exact current names from
  `qa-probe.mjs`.
- The gate's `--selftest` grows to 22 cases, adding rename+demote, same-severity, promote, missing
  replacement and unbound-ack coverage.
