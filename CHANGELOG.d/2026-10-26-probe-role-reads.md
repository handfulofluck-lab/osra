### Probe — a guardian and a co-parent can still read what the matrix says they may (plan 2.7)
- New `Q6c` (guardian) and `Q6d` (co-parent): Q6's no-permission sessions walk the 24 routes that name no
  permission. These are the reads of their own family, by its real child and device ids, plus
  `POST /v1/ws-ticket`, and each must be admitted. This is the positive half of the matrix's Co and Gu cells,
  which only refusals covered before. It needs no extra logins.
- It pins that `GET /v1/digests/prefs` stays open to every parent after #354 made the digest writes
  owner-only, which closes the digest GAP rows Claude listed on #326.
- `docs/QA/security/authz-matrix.md`:
  - §1a cites Q6c/Q6d on those routes, and Q7 for the device cells of `PUT /v1/digests/prefs` and
    `POST /v1/digests/send-now`;
  - §6 says what is still open;
  - the `GET /v1/digests/prefs` line number is corrected (158 → 159).
- Measured on `main@7ff1957`, local stack: 193 passed, 0 failed, 0 x 429. Mutant (`requireOwner` added to
  `GET /v1/digests/prefs`): 191 passed, 2 failed, both naming `GET /v1/digests/prefs -> 403
  owner_role_required`.
