### Infrastructure — prepare bounded Mac metadata access (#887, #893; roadmap 5.8)

- Prepare a separate Mac principal with literal infrastructure-metadata actions, reviewed role aliases,
  independent user/production-session deny ceilings and per-user monitoring. Keep the original boundary
  key-creation deny; add stricter key guards for review. PC script/caller defaults remain unchanged.
- Read credentials through a login-Keychain credential process. Mac rotation commands refuse before
  accessing storage or AWS; phase 1 grants no IAM writes or administrator access.
- Prepare fixed-deadline guards, an all-current-key expiry job, narrow execution permissions and
  status/health alarms. Renewal requires the approved owner/MFA procedure and reconciled deadlines.
- Add fake-only/source-derived and mock-provider regression checks. No cloud, credential or Keychain
  action was performed. This draft requires independent review and private evidence before use.
