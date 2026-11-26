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
