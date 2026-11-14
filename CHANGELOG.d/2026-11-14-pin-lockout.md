### The parent-PIN gate keeps the wrong-try count across screens and restarts, and repeated failures lock it for growing periods (#630, osra-security#24)
- The count of wrong parent-PIN tries used to live in a field on `TamperGuardActivity`, so reopening a
  guarded screen started again at zero. It now lives in `PinAttemptStore`, over the **encrypted store beside
  the PIN hash**: the count, the wall time of the last failure, its monotonic reading, the boot it happened
  on, and the failure count the parent was last alerted for — five integers, no new plaintext file and no new
  secret. `PinLockout` holds the rule free of Android types.
- **Five wrong tries close the gate for 1 minute, then 5, then 15, then 1 hour, and then flat.** While it
  is closed **every PIN is refused, the right one included** — a back-off that still accepts the right PIN
  is a delay, not a lockout. The count is deliberately *not* reset when a window expires; only a correct PIN
  clears it.
- **Only the monotonic clock decides a window**, so changing the phone's date and time neither opens the
  gate early nor holds it shut: the wall reading is stored for the alert and never compared. A reboot
  restarts the monotonic clock, so the window is re-anchored to one full window from the first read after
  boot. A reboot costs a child that window and can never cost a parent more than one.
- **One parent alert per lockout**, not one per attempt, and the fifth wrong try still lands Home as it did
  before (#484). While the gate is closed the child reads one line, "Too many tries. Try again in N minutes,
  or ask your parent." — a plural resource (`pin_locked_notice`), so a one-minute window says "1 minute".
  Its Arabic value is the Arabic Language Bureau's line and is **not** in this change.
- **Verified by JVM unit tests only** (`PinLockoutTest`, 12 rows, `testPlayDebugUnitTest` green), with
  planted faults recorded beside the rows they redden. **Not verified on a handset**: that reopening the
  guarded screen on the Flip4 keeps the count, that the right PIN is refused inside the window, that a
  reboot costs one window, and that one alert per lockout arrives. Those rows are owed and are not claimed
  here.
