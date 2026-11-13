### Billing — Play purchase verification and real-time developer notifications (ADR-0041 D2, #620)
- `POST /v1/billing/google/verify` checks a purchase token with `purchases.subscriptionsv2`, refuses one
  bound to another family's account id (403), a forged or spent one (400) and Play's own outage (503),
  acknowledges the purchase, and reports the state through the entitlement seam. Owner-only, as
  ADR-0014 and D1 say.
- `POST /v1/billing/google/rtdn` re-verifies every push with `subscriptionsv2` and takes the **state from
  Play**: the notification type only names the `cause`. A cancellation therefore leaves the family
  `active` with `autoRenews: false` until the paid period ends, and the later expiry revokes it.
- A push whose Play call fails answers 503 so Pub/Sub retries; a redelivery of an applied `messageId`
  changes nothing. A purchase Play still shows as unacknowledged is acknowledged on the next push, which
  is the retry for a `/verify` whose acknowledgement failed.
- The family's Play account id is B1's stored random `store_account_id`, reached through
  `storeAccountIdFor(familyId)`; there is no key to rotate and no derivation a deploy depends on. The
  in-memory stand-in derives one only because it has nowhere to store it.
- The seam carries `source` (`google_play`/`app_store`/`web`/`grant`), `productId`, `expiresAt`,
  `autoRenews` and `storeRef` (was `externalId`), splits granting states from revoking states in its
  types, and hashes `storeRef` before anything is stored. Neither `storeRef` nor the account id appears
  in a log line, asserted by a test around a verify and a push.
- Not verified: no live Play purchase, no Pub/Sub subscription and no refund were exercised. Every row
  is synthetic fixtures through an injected transport; ADR-0041's maintainer-assisted claims 1–3 stay
  open.

### A refund ends the plan when we learn of it (#692)
- A Play refund arrives as a `voidedPurchaseNotification`, not a subscription notification, so until now it
  was logged as `no_subscription` and the family stayed on the plan until the subscription's `expiryTime` —
  which after a refund can be a year away.
- It now revokes with `state: "refunded"` and `cause: "voided_purchase"`, immediately, which is the same rule
  ADR-0041 D3 applies to a revocation and a chargeback: access ends when we learn of it. No Play call is
  spent — the store has already told us.
- A voided **one-time product** (`productType` 2) does not touch the plan, and a refund for a token we never
  bound answers 204 with a log line and no Play call, for the same reason an unknown purchase does.
- Rows: a refund of a bound subscription revokes with `refunded` and a second delivery changes nothing; a
  one-time void leaves the plan alone; an unknown token is 204. Each proved by breaking the branch that
  guards it.
