### Home no longer escapes the ring screen (#734)
- On the Flip4 (13 Nov, 20:24Z) the parent sent `ring`, the child pressed **Home**, and the ring screen went to
  the back of its own task — invisible since #731 gave it `taskAffinity=""` and `excludeFromRecents`. The alarm
  kept ringing at full volume with **no way to stop it on the phone**: the screen's only exit is the parent PIN,
  and the PIN was on a screen that could not be reached. Only the parent's `stop_ring` or the ring's own cap
  ended it.
- While a ring is running, the accessibility service that already watches the foreground window now brings the
  ring screen back in front of whatever was opened (`RingReentryPolicy`, `REORDER_TO_FRONT`, on the
  **monotonic** clock).
- **The exemption is by window class, not by package** (osra-security#31): only `RingActivity` and the two PIN-gate
  activities are left alone. Exempting the whole package let the child open the OSRA child app from the launcher
  during a ring and keep the alarm ringing — the same outcome by another door.
- A change declined **only because of the 1.5 s debounce** is deferred, not dropped: one delayed re-check runs at
  the end of the window (and does nothing if the ring has stopped by then). Dropping it left the launcher in front
  until something else opened.
- `RingActivity` itself is unchanged: Back and the volume keys are still swallowed, the parent PIN is still the
  only exit, `stop_ring`/`sos_clear` still dismiss it and the 5-minute cap still ends it.
- **Verified by JVM tests only** (`RingReentryPolicyTest`, 11 rows). **Not verified on a handset**: ring, press
  Home, and confirm the screen returns within ~2 s with the PIN reachable; then Home inside the debounce and
  confirm it still returns; then Home → open the OSRA child app and confirm the ring screen covers it. Those rows
  are owed and are not claimed here.
