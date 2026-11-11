# `site/` — the public website at osratech.com

The privacy policy (`/privacy`) and the account-deletion page (`/delete-account`) that the Google Play
listings link to (Play decision 5). The pages are the static files in the repository's top-level `site/`
folder. This stack serves them from a private S3 bucket (eu-north-1) through CloudFront, with a
DNS-validated certificate in us-east-1 (CloudFront only takes certificates from there) and alias records
for `osratech.com` and `www.osratech.com` in the existing Route 53 zone. `www` redirects to the apex.

It is **always on**: `up.sh` and `down.sh` never touch it, and it shares no state with `base/` or `env/`
(its own key, `site/terraform.tfstate`, in the same state bucket). Cost is about $1/month (CloudFront
and S3 at this traffic; the zone is already paid for).

```bash
cd infra/terraform/site
terraform init
terraform plan -out site.tfplan
terraform apply site.tfplan
```

**Changing a page:** edit the file under `site/`, then `terraform apply` again: each file's MD5 is its
`etag`, so only changed files upload. CloudFront caches for up to a day under the managed
CachingOptimized policy, so invalidate after a policy change that must show at once:

```bash
aws cloudfront create-invalidation --distribution-id "$(terraform output -raw distribution_id)" --paths '/*'
```

The privacy policy is legal text: a change to what it says needs Karim's approval, like any other
store-facing wording.
