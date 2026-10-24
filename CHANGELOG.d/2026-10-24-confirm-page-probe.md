### Tests — the probe presses the digest confirmation button the way a browser does (roadmap 2.7, #354)
- `qa-probe.mjs` gains section R, six checks against a live API: the mailed link's page posts the token
  back and is never cached, a form POST reaches the handler (the 415 that #354 shipped and fixed would
  fail `R2`), a malformed token gets the 400 page, a JSON caller keeps JSON, no other route reads form
  bodies, and the form body is bounded at 1 KB.
- The probe still has no mailbox and no database connection, so it uses a well-formed unknown token; the
  confirmed case stays a unit test. Each check was shown to fail against a broken build (`docs/TESTING.md`).
- `docs/QA/security/authz-matrix.md` lists the two confirmation routes #354 added, which take no session,
  with their answers and the tests and probe checks that cover them.
