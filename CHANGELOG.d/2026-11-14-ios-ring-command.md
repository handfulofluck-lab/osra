### OSRA Kids iPhone: parent ring command (#750)

- Add the parent `ring` and `stop_ring` commands with a five-minute cap, an AlarmKit backend on iOS 26+, persistent ring state, and parent-PIN access.
- Report child dismissals, PIN stops, parent stops and timeout through server-owned alert body keys; coalesce dismissal pushes for 60 seconds with atomic, expiring Redis reservations while keeping every event.
- Check restart timeouts against the original command's server timestamp. Online early timeouts resume with the remaining seconds; offline expiry records `afterRestart`, with its own localized parent line.
- Add localized parent rendering and an update-required reason for older iOS versions. Bureau-approved English and Arabic are included; final-head screenshot review, full CI, independent verification, and the Mac test-bed KR01 and escape rows remain required before merge. No physical-device evidence or Critical Alerts entitlement request is claimed here.
