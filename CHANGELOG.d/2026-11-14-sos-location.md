### SOS alerts carry where they were sent from (#672)
- The child agent attaches the phone's last known fix to the SOS alert — latitude, longitude, accuracy,
  the time the platform took it, and its age — and starts a fresh high-accuracy fix the same way
  `locate_now` does, so a follow-up location ping usually lands within seconds of the alert.
- The parent app's SOS notification says that a place exists and how old it is, **and does not put the
  coordinates on the lock screen**: "Location from 3 min ago. Tap to see it on the map." The numbers live in
  the alert's detail — the Arabic Language Bureau's sentence ("آخر موقع: …، قبل 3 دقائق"), one accuracy
  clause when the fix carries one, **Show on map** as the primary action, and a quiet **Copy coordinates**
  that copies five decimals. Where the in-app map cannot draw (an iPhone build with no map key), **Open in
  Maps** hands the point to the phone's own maps app.
- The coordinates are wrapped in **LRI U+2066 … PDI U+2069 in code, for every language**: in a
  right-to-left line the two numbers are separate left-to-right runs and used to draw longitude first, so a
  parent reading the line aloud or typing it into a map reached another country. The marks are direction,
  not words, and are not in the ARB.
- Ages **round up**: 119 minutes reads "about 2 hours", never "1 h ago" — a parent must not be told a fix is
  fresher than it is.
- Arabic: two whole lines per plural case replace the three joined keys (`alertSosWhereMinutes`,
  `alertSosWhereHours`), «آخر موقع» rather than «قرب» so the minutes cannot be read as the age of the SOS,
  and «عرض على الخريطة» for the button. The notification's own sentence and the three new action strings are
  **provisional, pending the Arabic Language Bureau**.
- The API normalises the location before storing it (numbers, ISO time; a coordinate that cannot exist is
  dropped with the rest of the metadata untouched) and **never rejects an SOS for it**. A coordinate written
  as `0x10` or `1e1` is not a number.
- **Privacy, review of this head:** a guardian who was given `alerts` but not `location` receives the alert
  on the list and on the realtime channel **without the five location keys** (ADR-0014 amendment, decision
  3), and the nightly purge removes those keys from alerts older than the 30-day location window while the
  alert itself stays (ADR-0028 decision 5). The five keys are the only thing removed, and the alert always
  survives.
- An unpaired phone asks for no fresh fix: nobody could read it, and an ongoing location notification would
  sit on a device nobody manages.
- **No place name**: neither the API nor the app has a reverse geocoder, so "where" is coordinates plus age.
  **Nothing was added to the push payload** — #410/#395 made every parent push a data-only wake, and the
  visible row is built on the device.
- One new dependency in the parent app, `url_launcher`, for **Open in Maps** only.
- Verified by unit tests only, with the mutants recorded beside each row: `services/api` vitest, the
  `apps/child-android` JVM suite (`testPlayDebugUnitTest`, `testFullDebugUnitTest`) and `assembleDebug`, and
  `apps/parent-app` `flutter analyze` + `flutter test`. **Not verified on a handset**: SC-1.9 (an SOS whose
  alert carries a location under 60 s old), and the UI/UX Bureau's device pictures are owed — this change
  was made without a phone.
