# `email/` — outbound email from osratech.com (AWS SES)

Play decision 11 A (Karim, 11 Nov 2026) moves the API's email from Resend to AWS SES; the sender is
`SesEmailSender` in `services/api/src/lib/email/index.ts` (#573). This stack is the infrastructure half:

| Resource | Why |
|---|---|
| SES domain identity `osratech.com`, Easy DKIM 2048-bit | Mail is signed as the domain, so receivers can check it |
| 3 DKIM CNAMEs in the Route 53 zone | SES verifies the domain through them (usually within an hour) |
| Custom MAIL FROM `bounce.osratech.com` + its MX and SPF TXT | SPF passes **aligned** with the From domain, which DMARC needs |
| `_dmarc.osratech.com` TXT `v=DMARC1; p=none` | A published policy, monitor only; no reports are sent anywhere yet |
| IAM role `osra-staging-api-task` | The API task's runtime role: `ses:SendEmail` on this identity only, and only with a From on `osratech.com` |

It is **always on** like `site/`: `up.sh` and `down.sh` never touch it, and it has its own state key
(`email/terraform.tfstate`). It costs nothing until mail is sent ($0.10 per 1,000 emails).

```bash
cd infra/terraform/email
terraform init
terraform plan -out email.tfplan
terraform apply email.tfplan
aws sesv2 get-email-identity --region eu-north-1 --email-identity osratech.com \
  --query '{verified:VerifiedForSendingStatus,dkim:DkimAttributes.Status,mailFrom:MailFromAttributes.MailFromDomainStatus}'
```

Then bring staging up with email on (an environment variable, for the same reason as `push_enabled`:
`up.sh` forwards its arguments to base too, which does not declare the flag):

```bash
TF_VAR_email_enabled=true ./infra/terraform/up.sh
```

With `email_enabled = true`, `env/` attaches the task role and sets `EMAIL_PROVIDER=ses`, `EMAIL_FROM`
(default `OSRA <no-reply@osratech.com>`) and `AWS_REGION` on the API container. Off (the default), the
API keeps its console sender and the task has no AWS credentials at all.

## The SES sandbox

A new account can only send to **verified** addresses, 200 a day. That is enough for staging tests with
our own inboxes (verify one with `aws sesv2 create-email-identity --email-identity <address>`), not for
real parents. Leaving the sandbox is a request to AWS (SES console → Account dashboard → Request
production access): mail type Transactional, website `https://osratech.com`, and a description of the
mail (password resets, email verification and account notices only; no marketing; bounces and
complaints are handled). AWS asks for the website to be live, so it goes in after the `site/` stack is up.

## Not here yet

- **Receiving mail for `support@osratech.com`.** The zone has no MX for the apex, so nothing sent to the
  domain is delivered. That is a separate choice (SES receiving into S3 is only in some regions, or a
  forwarding service), recorded as an open item in the team notes.
- **Production (eu-central-1).** SES identities are per region; production gets its own apply of this
  stack with `-var region=eu-central-1 -var environment=production` and its own state key when it exists.
