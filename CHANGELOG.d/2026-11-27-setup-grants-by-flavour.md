### API — Full phones are protected only after notification access, and setup sends one parent notice (#1230, #1208, osra-security#82)
- The server now asks for the same grants the phone does: Full builds need notification access as an
  eighth required grant, Play builds keep their seven. Protection and "Phone is protected" arrive only
  when the last one is granted.
- Pairings that already completed keep their completion: the new rule never reopens them.
- The phone's immediate "setup not complete" notice and the server's 30-minute reminder now share one
  key per pairing (`setup_incomplete:<deviceId>`). Whichever comes second refreshes the same row instead
  of paging the parent again, and a notice still queued on the phone after completion is dropped.

**Review follow-up (osra-security#82, #87; G32a):**
- A completed pairing whose server-validated grants show a newly required grant missing now accepts the phone's #1208 notice: one row under the shared key, one push, `setupCompletedAt` left set. A row from the first-setup episode is re-raised in place (unread). A completed pairing with every required grant still drops a stale retry.
- The setup-notice reads and writes run on the locking transaction's client; publish and push run after commit. New `storeAlertOnce(input, tx)` in `lib/alerts.ts`; `withSetupLock`/`withSetupOpen` pass `tx` and the locked state.
- New real-Postgres test `device-setup-order-db.test.ts` (own schema on the CI test database) proves completion/notice ordering, rollback with no dispatch, and the upgrade and stale-retry cases.
- `qa-probe` G32a now requires a successful device read and `setupCompletedAt === null`.
