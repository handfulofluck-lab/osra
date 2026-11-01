### API — the client build is written only when it changes (#528 review, before the agent sends the header)
- **What it costs now.** `onResponse` wrote `Device` on **every** device request and `ParentPushToken` on every
  parent request. That is invisible today because no client sends `X-OSRA-Client`, and it becomes one row write per
  15-minute poll the moment the agent does — the load roadmap 5.8 exists to cut.
- **The fix** is an `updateMany` whose `where` matches only when a stored column differs, so an unchanged poll
  writes nothing.
- **The trap inside it, named in the code:** Prisma's `{ column: { not: value } }` does **not** match a NULL column,
  so a device reporting its build for the first time would never satisfy the predicate and the write would silently
  never happen. Each column reads `column IS NULL OR column != value`, and a row asserts that shape field by field.
- Rows: `client-header-hooks.test.ts` (9) — the device's own write, the null-safe `where`, and claim 10's
  "a parent's request leaves the device's build alone" now covering both call shapes.
