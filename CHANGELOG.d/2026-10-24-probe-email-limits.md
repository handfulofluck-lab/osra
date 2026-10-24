### Probe — the email limits from #354 are checked against a live server (plan 2.7)
- `Q6` and `Q6b` now also send `PUT /v1/digests/prefs` and `POST /v1/digests/send-now` as a guardian and
  a co-parent with no permissions, and expect `403 owner_role_required`.
- New `Q9`: an 81-character `familyName` is refused at registration (400); a digest list of six addresses
  is refused (400); an address that isn't a parent of the family stays `pending` and send-now leaves it out,
  while the parent's own address is `confirmed`. The check puts the family's digest back to off afterwards.
- Not probed: the 21st invite of the day (429). Reaching it sends 20 real invites on a deployed API;
  `test/invites.test.ts` pins it.
- Measured on `main@baf3290`, local stack: 183 passed, 0 failed, 0 x 429. Mutant (four guards removed at
  once: `requireOwner` on PUT prefs, `.max(80)` on `familyName`, `.max(5)` on the digest list, and the
  confirmation filter in `confirmedRecipients`): 178 passed, 5 failed, each naming the removed guard.
