### Infrastructure — SES can send as osratech.com (#584, Play decision 11 A)
- New always-on `infra/terraform/email/` stack: the osratech.com SES identity with 2048-bit DKIM, a custom
  MAIL FROM (`bounce.osratech.com`) so SPF aligns, and DMARC in monitor mode (`p=none`).
- The API task gets its first runtime role, `osra-staging-api-task`, which may only send as `*@osratech.com`.
- `TF_VAR_email_enabled=true ./infra/terraform/up.sh` attaches the role and sets `EMAIL_PROVIDER=ses`,
  `EMAIL_FROM` and `AWS_REGION`; off by default, so a staging session without it is unchanged.
