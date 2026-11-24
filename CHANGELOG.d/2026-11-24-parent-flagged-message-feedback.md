### Parents can mark flagged messages as concerning or not concerning (#1065)
- Social Monitoring and eligible alert detail surfaces now show the Bureau-approved feedback controls in English and Arabic, including the latest voter, optimistic updates, Undo, saving and retry. SOS and location alerts do not offer votes.
- New parent-only `POST` and `DELETE /v1/social/events/:id/feedback` endpoints support changeable and idempotent withdrawal, with `social` permission and family isolation. A co-parent sees the latest voter by name.
- Votes stay tied to the encrypted vault event with no message text copied to logs, Redis, push or analytics. Message, child, family and retention deletion remove votes through database cascades.
- Counts-only evaluation suppresses groups below five current votes and excludes withdrawn votes on the next read; no training pipeline or miss-rate claim is added.
- Verification: API 1,391 passed / 10 skipped; Parent 1,255 passed / 1 skipped; fail-first authorization and widget/provider tests included.
