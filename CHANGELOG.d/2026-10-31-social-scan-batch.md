### API + child agent — a social-scan flush is one request per six captures, not one per capture (#490)
- On the Flip4 (#484 row I1) a flush of six captures went out as six `POST /v1/social/scan`, waking the radio
  six times where once would do.
- **API.** `POST /v1/social/scan` accepts `{ items: [...] }` with 1 to `SCAN_BATCH_MAX` (6) items and answers
  `{ results: [{ ok: true, … } | { ok: false, reason }] }` in the same order, so one bad item does not drop the
  others. More than 6 items is a 400 for the whole body. The single-item body older agents send is answered
  exactly as before. The per-item checks (child and device ownership, consent, scoring, vault, throttled
  alert) are one function shared by both bodies.
- **Agent.** `SocialScanQueue.flush()` sends its rows through `ScanBatchSender`, six per request
  (`ScanQueuePolicy.ITEMS_PER_REQUEST`). It deletes only the rows the server answered `ok` for, counts
  refused rows down, and keeps every row of a request that failed on the network (with a retry scheduled).
- Rows: five API rows (array body, 6 taken and 7 refused, a mixed batch, an invalid item, the single body)
  and eight agent rows in `ScanBatchSenderTest`.
