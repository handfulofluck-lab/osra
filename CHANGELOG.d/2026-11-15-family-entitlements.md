### API — server-owned family plan entitlements (#619)
- Durable, hash-only purchase records now back the existing Play billing seam, with replay protection and a stable random 128-bit purchase-account identifier per family.
- Guardians can read their family's finite plan; only the owner receives the purchase-account identifier. Store grace and account hold follow the store, and ended plans change enforcement at the next family-local 10:00 rather than at night.
- A typed `402 plan_required` gate and shared premium-rule filter are implemented, but no existing feature is gated: `PREMIUM_FEATURES` remains empty until Karim's M3 decision.
- A maintainer-only script writes finite beta grants through an injected AWS CLI boundary. No lifetime grant, public grant route, store call or agent AWS access was added.
