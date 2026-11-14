### Infrastructure — production Terraform for Frankfurt, plan only (#714)
- The staging stacks now take every production setting as a variable whose default is today's staging value, so one
  codebase plans both: Multi-AZ PostgreSQL with 14 days of point-in-time restore and deletion protection, a cache
  replica with failover and TLS (`rediss://`), two NAT gateways, a WAF on the load balancer, e-mail alarms and a
  US$400 monthly budget, all for `api.osratech.com` in `eu-central-1`.
- Backends come from `backend/*.hcl`; production assumes a role in `osra-production` and pins its account ID, so a
  wrong profile fails before it plans. A new `bootstrap-state` stack creates production's state bucket.
- `down.sh` refuses production; `up.sh` plans production and applies only with `OSRA_PROD_APPLY=yes`, and migrates
  production without the demo seed.
- `terraform test` checks with a mocked provider (no credentials) pin both environments' settings; CI runs them.
