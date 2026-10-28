### Parent app — an invite's permissions are joined with the Arabic comma in Arabic (#426)
- The pending-invite subtitle on the family screen joined the permissions with a Latin `, `, so an Arabic parent read
  `الموقع, التنبيهات`. A new `listSeparator` key (EN `, `, AR `، `) now joins them, and the existing role and permission
  row in `test/family_screen_l10n_test.dart` pins the Arabic comma (it asserted the Latin one before).
