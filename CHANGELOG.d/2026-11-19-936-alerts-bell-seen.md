### Parent app — clear the notifications bell count after opening the feed (#936)
- Opening `/alerts` and loading page 1 marks the displayed alerts as seen so the dashboard bell badge clears on return, while preserving explicit alert acknowledgement (`POST /v1/alerts/:id/ack`), keeping unseen counts intact on failed feed loads, and incrementing again when new or updated alerts arrive.
