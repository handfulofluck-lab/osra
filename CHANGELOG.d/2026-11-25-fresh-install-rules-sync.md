### Child Android — fresh installs fetch and retry rules without a parent save (#1130)
- Every scheduler start now enqueues the existing immediate rules worker instead of relying on its six-hour periodic job or a parent-triggered `rules_updated` push. Pairing uses that same single startup request rather than enqueueing a duplicate.
- A paired device whose rules cache is still empty returns WorkManager `retry`, so backoff continues until rules arrive. The applied-rules version remains null until a fetched rule set is persisted, and the existing empty-cache fail-closed enforcement is unchanged.
- JVM wiring tests cover immediate startup, empty-cache retry and duplicate-request prevention. Fresh-install Pause behavior still requires independent hardware verification.
