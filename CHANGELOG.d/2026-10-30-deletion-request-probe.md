### QA probe — the account-deletion request is not an account oracle (#442 PR 3 / #467)
- New probe section AD. `POST /v1/account/deletion-request` is public, so it must not reveal whether an
  address has an account. AD1: a known and an unknown address both get 202 and one identical body. AD2: they
  take the same time within noise (median of six alternating requests each, after one warm-up of each).
- Fourteen requests stay inside the route's own 20-a-minute bucket. The known address is a fresh parent
  registered for this section.
