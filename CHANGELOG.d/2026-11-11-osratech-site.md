### Website — osratech.com serves the privacy policy and the account-deletion page
- `site/` holds three static pages: the home page, `/privacy` (written from the Play data-safety answers in
  `docs/store/play/data-safety.md` and Karim's decisions 5 to 17) and `/delete-account` (the in-app steps,
  the email route, and what is deleted and kept).
- `infra/terraform/site/` serves them over HTTPS: private S3 bucket, CloudFront with origin access control,
  an ACM certificate for the apex and `www`, and alias records in the existing zone. Always on, about
  $1/month, independent of the on-demand staging stacks.
