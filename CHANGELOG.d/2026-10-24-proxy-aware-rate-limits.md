### API — rate limits key on the client address behind the load balancer (plan 2.7)
- `TRUST_PROXY` (a hop count; `1` behind the ALB in `infra/terraform/env/ecs.tf`) sets Fastify's
  `trustProxy`. With it, every bucket keys on the client address, read from the entry the load balancer
  adds to `X-Forwarded-For`. Any other value, including `true`, stops the API at boot. Unset trusts
  nothing, which is right for local development.
- The limiter's counts live in Redis under `rl:`, so every API task enforces one shared limit, not one
  limit each. Each key expires with its one-minute window.
- When Redis is unreachable, the global bucket (200 a minute) lets requests through. Two buckets refuse
  instead, with `503 temporarily_unavailable` and no driver message:
  - the auth bucket (20 a minute);
  - the new pairing-claim bucket (`POST /v1/devices/pair/claim`, 10 a minute).
- A failed pairing claim logs `metric: "pair_claim_failed"`, without the code. It is a count to watch,
  never a brake.
- Staging gets a CloudWatch alarm when Redis memory passes 70%. Under `noeviction`, a full node refuses
  writes, revocations included.
- The three bucket configs live in one place, `src/lib/rateLimits.ts`. `test/rate-limits.test.ts` checks:
  - the hop-count parsing;
  - separate buckets for two clients behind one proxy;
  - that extra `X-Forwarded-For` entries don't change the bucket;
  - the claim limit;
  - one count across two instances;
  - both failure modes.
- Operators: a limit now survives an API restart. See `docs/TESTING.md` §6 (traps).
