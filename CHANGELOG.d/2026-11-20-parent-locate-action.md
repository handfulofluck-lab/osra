### Parent app — the parent can finally ask a phone for its location (#869)
- The parent app could **show** a `locate_now` in a device's command history but had no way to **send** one: the
  only occurrence of the command in `apps/parent-app/lib` was its display label. So "Locate the child" had nothing
  behind it, on any build — which is what the 16 Nov owner test hit when the Location view had no position.
- A **Locate now** action now sits with the other device commands (ring, stop, lock, unlock, pause, resume). It
  reuses the Bureau's existing line (`commandLocateNow`, «تحديد الموقع الآن»), so no new copy and no new translation.
- A queued locate refreshes the child's location read, so a fresh fix appears without waiting for the next poll.
- **A refusal is shown as a refusal:** the server answers `{status: "failed", reason}` when the phone's grant cannot
  answer (`locationGrant.ts`), and that already reached the parent through `commandRefusalText` — the row asserts the
  parent is told it *was not sent*, never that it was queued.
- What this does **not** do: it does not add a map to the Location tab. That tab's map card is a placeholder by
  design (`child_detail_screen.dart:807-822`); the per-child map lives on `/map`.
- Verified: CI only — there is no Flutter toolchain on this PC, so the two widget rows have never executed.
