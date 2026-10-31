### Parent app + child agent — the picker knows which apps Android considers essential, and a dead-end MFA message is gone (#199)
- **Item 1, the dead-end login message.** `mfa_reenroll_required` told the parent to "sign in with an
  unused recovery code", and a recovery deletes the rest of the batch, so there was none. The message now
  says the setup was reset but not finished, names *Lost your authenticator?* while the setup screen is
  still open, and otherwise points at support. Pinned verbatim in `auth_provider_test.dart`, including a
  negative assertion that the old sentence cannot come back.
- **Item 5, essential apps in the picker.** `DeviceApp.essential` is a **nullable** column (no backfill):
  `null` is "this phone has not reported it", which the picker treats exactly as before — selectable, no
  label. A rule on the dialer would silently do nothing, so an app the phone reports as essential is
  shown as **"Always allowed (needed for calls and safety)"** and cannot be selected.
  - Computed **on the device** with `EssentialPackages.isEssential(packageId, PackageFacts)` and sent on
    the inventory report (`inventoryApp(...)`, pure and JVM-tested). Only the phone knows the OS roles,
    and a name table is what the #83 review refused to trust.
  - The server **stores** it and never enforces with it; the route is device-only, so no parent request
    can set it. Migration `0028_device_app_essential` adds the column with no default.
  - Rows: `InstalledAppsEssentialTest` (the dialer and launcher leave the phone as essential, a browser
    does not, and the wire value is the shared rule), the API's round-trip plus "absent stays null", and
    a widget row where the essential app is labelled and disabled while the unreported one is selectable.
  - Mutants run: `essential = false` in the mapping reddens three JVM rows; `?? false` in the normaliser
    reddens two API rows; dropping `!essential` from the list tile reddens the widget row.
- **Not in it:** `mfaRecoveryStartedAt` and the #183 session-revocation ordering (item 2 and 3 are
  superseded by ADR-0031 per Claude's queue note), and the picker's second line for non-essential apps.
- How the device-admin sheet renders the flag needs the Flip4; that is a `#484` row.
