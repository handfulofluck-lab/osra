### Parent app — a read the invite does not cover says so, and names the fix (ADR-0014 decision 7, #400)
- `ReadPermissionRequired.from(error)` recognises exactly the server's `403 { error: "permission_required" }` and
  keeps which permission was needed. A `403 cross_child_forbidden`, a `403 session_revoked`, a non-403 with the same
  body, and a timeout all return `null`: telling a guardian to ask the owner for access when the real problem is a
  stale token would send them to the wrong person.
- The alerts screen shows one sentence naming the owner instead of "failed to load": *"Your family owner can give you
  access to this."* / *"يمكن لمالك العائلة منحك حق الوصول إلى هذا."* The permission name is not interpolated — `alerts`
  in the middle of an Arabic sentence reads as a bug to the person reading it.
- Tests: six rows on the mapper (which refusals count, and which do not) and the two localized sentences. The screen's
  render path is covered by `flutter analyze` and the suite, not by a widget row — said plainly rather than implied.
