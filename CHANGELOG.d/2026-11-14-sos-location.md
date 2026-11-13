### SOS alerts carry where they were sent from (#672)
- The child agent attaches the phone's last known fix to the SOS alert — latitude, longitude, accuracy,
  the time the platform took it, and its age — and starts a fresh high-accuracy fix the same way
  `locate_now` does, so a follow-up location ping usually lands within seconds of the alert. On the Flip4
  run that raised this (#665, 19:15Z) the alert reached the parent in 5.2 s with `{deviceId}` and nothing
  about where, while a 13-minute-old fix sat on the phone.
- The API normalises that location before storing it (numbers, ISO time; a coordinate that cannot exist is
  dropped with the rest of the metadata untouched) and **never rejects an SOS for it**: an alert with no
  fix, or with a broken one, is still stored and pushed. That rule has its own test.
- The parent app's SOS notification now reads "SOS — near 25.276900, 51.521100, 3 min ago" instead of the
  generic line, with an Arabic provisional sentence pending the Arabic Language Bureau, and the alert's
  dialog offers **Show on map**, which opens the family map centred on that fix with a marker on it.
- **No place name**: neither the API nor the app has a reverse geocoder (the map screen calls that a
  non-goal), so the sentence carries coordinates plus age. A street name needs a provider and a key, which
  this change does not invent.
- **Nothing was added to the push payload.** #410/#395 made every parent push a data-only wake with no
  alert text in it; the visible row is built on the device from `/v1/alerts`, so the "where" sentence lives
  there, in the family's language. The issue asked for the sentence in the push body; that shape is
  deliberately not what this server sends, and undoing #410 was not in scope.
- Verified by unit tests only, with the mutants recorded beside each row — `services/api` vitest (the two
  files this touches: 33/33; the full API suite on the authoring host had 22 timeouts in `auth.test.ts` and
  two other files, and `auth.test.ts` passes 34/34 when run alone, so those are load, not this change; CI
  should be the record), `apps/child-android` JVM suite (both flavours green, `assembleDebug` green),
  `apps/parent-app` `flutter analyze` clean and `flutter test` 637/637. **Not verified on a handset**: the
  phone row is SC-1.9, an SOS whose alert carries a location under 60 s old.
