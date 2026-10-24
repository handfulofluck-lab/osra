### Probe — the real pairing-claim and login routes keep their own rate limits (plan 2.7, #376)
- New section S, after R:
  - S1 sends malformed claims to `POST /v1/devices/pair/claim` until it answers 429. It must report
    `x-ratelimit-limit: 10` and refuse by the 11th request.
  - S2 does the same on `POST /v1/auth/login`, which must report 20 and refuse by the 21st.
- The limiter counts before validation, so no code is tried and no session is created. These 429s are
  the answer under test and are not counted toward the probe's 429 abort.
- This closes the gap Claude found on #376: `test/rate-limits.test.ts` uses stand-in routes, so before
  this, nothing noticed a route losing its bucket. CI does not run the probe, so the claim route also gets a
  unit test, `test/pair-claim-rate-limit.test.ts`. It registers the real `deviceRoutes` and expects ten
  400s and then 429 with `x-ratelimit-limit: 10`, and it fails when the route loses its bucket. The auth
  bucket was already guarded in CI by `test/mfa-reset-rate-limit.test.ts`. `FakeRateLimitRedis` moved to
  `test/helpers.ts` so both tests share it.
- Measured on `main@a7c1c56` (with #376), local stack:
  - clean: 191 passed, 0 failed, 0 x 429;
  - `/pair/claim` without its bucket: S1 fails (`x-ratelimit-limit=200`, no 429 in 12);
  - `/login` with a 40-a-minute bucket: S2 fails (`x-ratelimit-limit=40`);
  - `/login` with no bucket at all: the run aborts at an earlier login (exit 2).
