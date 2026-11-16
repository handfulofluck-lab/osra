### OSRA Kids iPhone: keep ringing after a lock-screen stop (#760)

- Schedule a chain of AlarmKit alarms when a ring starts: the existing immediate alarm plus deterministic sentinel alarms at 6-second intervals until the five-minute cap. Stopping one leaves the next already scheduled, so a child who slides to stop from the lock screen cannot silence the ring while the OSRA Kids app is suspended or killed.
- Report only the parent command IDs to `RingController`; sentinel IDs are hidden so normal dismissal detection still works when the app is awake.
- Persist the set of active command IDs so a restarted app can still tell which AlarmKit alarms belong to an active ring instead of counting a restart as a dismissal.
