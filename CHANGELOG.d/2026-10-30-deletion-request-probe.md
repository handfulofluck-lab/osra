### QA probe — the account-deletion request is not an account oracle (#442 PR 3 / #467)
- New probe section AD. `POST /v1/account/deletion-request` is public, so it must not reveal whether an
  address has an account. AD1: a known and an unknown address both get 202 and one identical body. AD2: they
  take the same time within noise. Each sample is an address's first request, because a repeat inside the
  minute is the mail cooldown and does no work: five fresh known addresses against five fresh unknown ones.
- Eleven requests stay inside the route's own 20-a-minute bucket. On the local stack the work behind a
  known address costs well under a millisecond, so AD2 is meant for staging, where the mail provider is real.
