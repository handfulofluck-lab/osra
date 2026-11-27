# ADR-0049 — Resolve a daily-limit time request in one transaction

Status: Accepted for implementation. [Claude's decision on #1179](https://github.com/handfulofluck-lab/osra/issues/1179#issuecomment-7193517354).

The parent can give a child another 15 or 30 minutes after a daily-limit request, or decline it. Retries and decisions from another caregiver can reach the API at the same time. Calling the general bonus route and then acknowledging the alert separately would allow extra time to be granted twice or leave the request open after a successful grant.

`POST /v1/alerts/:id/time-decision` accepts `{"action":"grant","minutes":15}`, the same shape with 30, or `{"action":"decline"}`. The request needs family membership, parent authority, both `alerts` and `rules` permissions, and active child consent. It applies to `app_blocked` alerts with the daily-limit time marker. Existing time requests with a string-valued duration are accepted.

PostgreSQL locks the request's alert row while the API records the decision. For grants, the same transaction increments the daily bonus and queues one command for each paired device. It then stores the resolution and acknowledges the alert. A failed write rolls back the entire decision. A second qualifying caregiver or a retry sees a conflict with the stored receipt. If an older app already acknowledged the alert, the conflict has a null receipt. The ordinary acknowledgement route keeps pending time requests open for a decision.

The receipt stores a snapshot of the deciding caregiver's display name and the server's decision time beside the chosen action and duration. The API reads this from a server-owned row keyed by alert ID, so the device-supplied alert metadata cannot set it. Ordinary alert listings include this receipt when one exists. It follows the alert's lifetime via its foreign key. The trade-off is an additional row per decided request and a relationship read when listing alerts.

Device wake and rule broadcast run after commit. The transaction guarantees one stored bonus increment and one queued command per paired device for the request. Device delivery and application use the existing command path. The dated and keyed changes to the general bonus route are tracked in [#1184](https://github.com/handfulofluck-lab/osra/issues/1184).
