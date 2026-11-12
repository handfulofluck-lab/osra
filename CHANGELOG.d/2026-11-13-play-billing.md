### Billing — Play purchase verification and real-time developer notifications (ADR-0041 D2, #620)
- `POST /v1/billing/google/verify` checks a purchase token with `purchases.subscriptionsv2`, refuses one
  bound to another family (403), a forged or spent one (400) and Play's own outage (503), acknowledges
  the purchase, and reports the resulting state through the entitlement seam.
- `POST /v1/billing/google/rtdn` accepts the Pub/Sub push, authenticates it with the OIDC token (no
  parent session), maps Play's notification types to entitlement changes, dedupes on `messageId`, and
  acknowledges an unknown type with a logged reason rather than a guess.
- The plan is written only through `services/api/src/lib/entitlement.ts`. That module's in-memory store
  is a stand-in: B1 (#619) replaces it with the `family_purchases`-backed one behind the same calls.
  No migration and no table change here.
- Not verified: no live Play purchase, no Pub/Sub subscription and no refund were exercised. Every row
  in this PR is synthetic fixtures through an injected transport; ADR-0041's maintainer-assisted claims
  1–3 stay open.
