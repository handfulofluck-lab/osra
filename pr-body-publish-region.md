## 1. Restatement — what I understood the ask to be

> "I understand the ask as: the API publish workflow must authenticate to whichever ECR registry
> `AWS_ECR_REPOSITORY` names, not to one hardcoded region. Today the login asks for a password in
> `me-central-1` no matter what the variable says, so pointing the variable at another region's
> repository produces a `400 Bad Request` from `docker login` — an error that looks like a credential
> problem and is really a region mismatch. This is a prerequisite for the ECR replication experiment
> on #258, which needs a publish into `eu-north-1`."

## 2. Item / issue

- Relates to: #258 (the ECR push blocker; this is the CI-side prerequisite for the replication experiment)
- Roadmap: `plan 5.8` (staging on AWS UAE)
- Acceptance: a publish dispatched with `AWS_ECR_REPOSITORY` pointing at `…eu-north-1…` logs in
  successfully and pushes there; the same dispatch with the `me-central-1` URL is unchanged.

## 3. What changed and why

| File:line | Change | Why |
|---|---|---|
| `.github/workflows/api-publish.yml:57-70` | The login derives `HOST` and `REGION` from `AWS_ECR_REPOSITORY` (`cut -d. -f4`) instead of hardcoding `--region me-central-1`; the resolved pair is echoed | A token minted in the wrong region is rejected by the registry it is presented to, and the failure text does not say so |
| `CHANGELOG.d/2026-10-23-publish-region.md` | Changelog fragment | `.github/` change (§8) |

Anything **not** changed that a reader might expect to be changed, and why:

- The `configure-aws-credentials` step still requests `aws-region: me-central-1`. That is the *control
  plane* region for `ecr:GetAuthorizationToken` when the run is a normal `me-central-1` publish, and
  changing it would alter what the OIDC session looks like to CloudTrail for no gain. If the
  experiment wins, the variable stays in `eu-north-1` for the push and this step keeps working because
  the role is region-agnostic for ECR (its policy names both repository ARNs).
- No retry/backoff was added. The workflow already fails loudly and the tag is immutable, so a re-run
  is a deliberate act; adding retries would hide the `UNSUPPORTED` region error this issue is about.

## 4. Gates I ran (paste raw output, not a summary)

```
$ node scripts/check-workflows.mjs --strict
0 error(s), 0 warning(s) across 9 workflow file(s)

$ node scripts/check-changelog-fragment.mjs
changelog fragment: CHANGELOG.d/2026-10-23-publish-region.md

$ node scripts/check-docs-links.mjs
0 broken link(s) out of 155 checked in 90 Markdown file(s)
```

Not run: the step itself only executes on `main` under the publish role (`if: github.ref ==
'refs/heads/main'`), so there is no branch-level execution of it. The first real proof is a dispatched
run, which is the point of the change.

## 5. What the reviewer must verify (falsifiable claims)

1. `aws ecr get-login-password --region "$(printf '%s' 222207908538.dkr.ecr.me-central-1.amazonaws.com | cut -d. -f4)"`
   is equivalent to the old hardcoded call — i.e. for the current variable the derivation produces
   `me-central-1` and behaviour on `main` is unchanged.
2. For `222207908538.dkr.ecr.eu-north-1.amazonaws.com` the derivation produces `eu-north-1`, and the
   resulting `docker login` no longer returns `400 Bad Request` (observed failure on the earlier dispatch
   when the hardcoded region was used).
3. `node scripts/check-workflows.mjs --strict` stays clean — i.e. the linter has no rule that the
   shell-level derivation trips (it also proves `secrets.` is not used in an `if:`).

## 6. Open questions, assumptions, deliberately not done

- Assumption: the repository URL format is always `ACCOUNT.dkr.ecr.REGION.amazonaws.com/repo`, which is
  the only form ECR returns from `ecr_repository_url`. Public-ECR hosts (`public.ecr.aws/...`) would
  need a different derivation and are out of scope; the workflow's `if:` already restricts it to this
  account.
- Question for the reviewer: does the region decision on #258 change this at all? If option 2
  (cross-region pull) wins, this change is still correct but not exercised — say so before merge so the
  merge message can record it accurately.
- Not done: nothing else in the publish path was touched (ADR/tag/build unchanged).

## 7. Discussion

- [ ] I have read the reviewer's point-by-point reply
- [ ] Every point is answered with evidence (or explicitly deferred to the human with `needs-human`)
- [ ] Any change to my restatement in §1 is re-stated and agreed before merge
- [ ] `docs/QA/DISCUSSION-LOG.md` updated with this exchange
