- A refusal can arrive two ways: a `200` with `{status:"failed", reason}` (mapped since #221) or an HTTP error.
  The second was shown as the wire code inside `Command failed: {error}`.
- `commandErrorText` keys on the shapes the routes actually send, verified against `services/api/src`: a
  `403 {error:"permission_required"}` from `requirePermission(...)`, detected by `ReadPermissionRequired.from`
  so one place decides the shape; a `429` from `@fastify/rate-limit`, keyed on the **status** because its body
  is Fastify's own and never carries `rate_limited`; a **reason** the agent would have used, which keeps the same
  sentence as a `200` refusal; and anything else **verbatim** — hiding an unknown code is the "queued" mistake in
  another costume.
- The geofence dialog's error goes through `readErrorText`: that route is gated by `requirePermission("location")`,
  so its refusal is the same shape every gated read already renders. No new copy.
- Copies: "You don't have permission to send {command} to {device}. Your family owner can give you access." and
  "{command} was not sent to {device}: too many requests right now. Try again in a minute." The permission is not
  named (`readPermissionRequired`'s reasoning: a guardian does not know the invite vocabulary). **The Arabic is a
  placeholder pending Karim's lines**; the rows pin it, so his wording changes the ARB and one literal each.
- Rows use the **real** bodies (403 `permission_required`, a Fastify 429), plus the geofence dialog. Mutants, each
  asserting the edit landed: the map back to the raw body reddens the 403 and 429 rows; removing the 403 mapping
  reddens the 403 row and the unit row.
