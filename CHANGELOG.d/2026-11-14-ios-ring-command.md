### OSRA Kids iPhone: parent ring command (#750)

- Add the parent `ring` and `stop_ring` commands with a five-minute cap, an AlarmKit backend on iOS 26+, persistent ring state, and parent-PIN access.
- Report child dismissals, PIN stops, parent stops and timeout through server-owned alert body keys; coalesce dismissal pushes while keeping every event.
- Add localized parent rendering and an update-required reason for older iOS versions. English and Arabic review, full CI, and the Mac test-bed KR01 and escape rows remain required before verification; this change does not claim physical-device evidence or an entitlement request.
