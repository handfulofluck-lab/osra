### Child agent — the parent-PIN step comes back after a relaunch (ADR-0010 §2, #440 follow-up)
- A paired agent with no parent PIN now always opens on the PIN step. Before, a relaunch between the
  parent's Allow and the PIN step (seen on the #440 Flip4 run) landed on the status screen, where setting
  the PIN was an optional button and Re-pair and Remove protection ran without one. ADR-0010 promises that
  the unprotected window is the setup screen only; `SetupResumePolicy` now enforces it at the top of
  `showStatus()`, which every route to the status screen passes through.
- `SetupResumePolicyTest`: the two states, and a source check that `showStatus()` starts with the gate.
