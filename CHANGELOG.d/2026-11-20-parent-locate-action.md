### Parent app — the parent can finally ask a phone for its location (#869)
- The parent app could **show** a `locate_now` in a device's command history but had no way to **send** one: the
  only occurrence of the command in `apps/parent-app/lib` was its display label. So "Locate the child" had nothing
  behind it, on any build — which is what the 16 Nov owner test hit when the Location view had no position.
- A **Locate now** action sits on the **Location tab**, next to the state a parent reads when there is no position,
  not in the device-command row: that row already wraps to three lines at 320 px and one more button pushed an
  existing control out of the tapped area. It reuses the Bureau's existing line (`commandLocateNow`), so no new copy.
- It asks **one phone**, and names it when the child has more than one: the button reads the phone's model, so a
  parent knows which device was queried and no device is unreachable (cross-family review F2).
- **What the queue answer is, stated honestly (review F1):** the POST answers `{status: "pending"}` before the phone
  has received the command, so the app does **not** re-read `/latest` at that moment — it would return the same 404
  or the same older fix. The new position appears when the phone publishes its ping: the `location` message on
  `/v1/ws` invalidates that child's location read, which is already covered by `realtime_refresh_test.dart`.
- **A refusal is shown as a refusal:** the server answers `{status: "failed", reason}` when the phone's grant cannot
  answer (`locationGrant.ts`), and that already reached the parent through `commandRefusalText` — the row asserts the
  parent is told it *was not sent*, never that it was queued.
- What this does **not** do: it does not add a map to the Location tab. That tab's map card is a placeholder by
  design (`child_detail_screen.dart:807-822`); the per-child map lives on `/map`.
- Verified: CI only — there is no Flutter toolchain on this PC, so the two widget rows have never executed.
