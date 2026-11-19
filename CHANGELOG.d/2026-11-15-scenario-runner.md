### QA — manifest-driven scenario runner with a no-device dry run (#797, #667)
- `scripts/hardware/scenario.ps1` validates a small JSON manifest before any lease or ADB call, refuses connection, clock, PIN, admin-removal and unrestored-device changes, and always injects the runner's serial.
- Runs save nine before-values plus lock state, collect cropped OSRA-only evidence in memory, execute typed steps, and restore/re-read everything in `finally` before releasing the lease.
- Missing data and empty result/test sets are `NOT RUN`, never `PASS`; dry-run output is explicitly marked and is not physical-device evidence.
- Pester and a nonempty `SC-0.1` dry run are wired into `workflow-lint`; all device boundaries are fake. No physical phone, real account, backend, credential or production action is used by K31's tests.
