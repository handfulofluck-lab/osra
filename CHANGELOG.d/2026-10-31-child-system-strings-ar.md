### Child agent — the Accessibility, device-admin and wipe lines speak Arabic (#480)
- On an Arabic phone, Android's Accessibility list, the device-admin sheet and the wipe notice on the
  pairing screen still showed English, because `values-ar` had no entry for them. The five lines now
  have Arabic, exactly as Karim approved on 2026-10-31 06:20Z
  (`arabic-review/2026-10-31-child-system-strings`, Q1–Q5): `accessibility_service_label`,
  `accessibility_description`, `device_admin_label`, `device_admin_description`, `wipe_detected_notice`.
- `app_name`, `app_name_ar` and `sos_tile_label` are brand names and keep the default on purpose.
- The tamper guard matches the device-admin screen with `getString(device_admin_label)`, which resolves
  in the same locale Settings uses, so the Arabic label is still recognised on an Arabic phone.
- Rows: `ChildSystemStringsTest` (each key exists in both files, the Arabic is the approved literal,
  the brand keys have no Arabic override). How the sheets render is a Flip4 row on #484.
