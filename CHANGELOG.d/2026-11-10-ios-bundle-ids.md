### iOS — the apps use the final store ids (decision 2B, #372)
- The child agent is `com.osratech.child`, its extensions `com.osratech.child.Monitor`, `.ShieldConfiguration`
  and `.ShieldAction`, and the app group (also the Keychain access group) `group.com.osratech.child`.
  The parent app is `com.osratech.parent` in all three build configurations. Same ids as Android (#452).
- Only identifiers changed: Swift module and type names stay. Nothing is installed yet, so no migration.
- New `apps/child-ios/scripts/check-identifiers.py` runs on Linux in iOS CI and fails on any other bundle
  id, app group or old `dev.familyshield.*` id; an extension that keeps the old group turns it red.
