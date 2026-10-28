### Parent app — a refused ring or lock is no longer reported as queued (ADR-0034 decision 3)
- The family map's Ring and Lock buttons answered "queued for {device}" to every `200`, including the
  `{status: "failed", reason}` the server now returns when the phone's own report says the feature is
  unavailable or `not_supported`. A parent whose command was refused up front was told it had been sent.
- The map now takes the same path as child detail: an immediate refusal is rendered with
  `commandRefusalText`, so one command never has two stories.
- `commandRefusalText` gained the `not_supported` line (`commandRefusedNotSupported`, EN + AR): the build or
  platform cannot do it at all, which is not a fault and not something the parent can fix by asking the child
  to open the app. An unknown reason still falls back to the raw code, as before.
- Two rows in `family_map_l10n_test.dart`, both pinning Arabic **literals**: the refusal sentence on the sheet,
  and the mapping (including the unknown-code fallback). Mutants: dropping the map's `status == "failed"`
  branch reddens only the sheet row; dropping the `not_supported` case reddens both — which is the property
  that matters, a row that cannot fail is worse than no row (#429 §7).
