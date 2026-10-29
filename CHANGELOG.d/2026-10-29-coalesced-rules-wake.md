### API — a rules change always wakes the phone, even when it joins a pending update
- `enqueueDeviceCommand` folds a `rules_updated` into a pending one instead of adding a row. Until now that
  path returned without a wake, so if the first wake was delayed or dropped by FCM, or was created while
  push was off, every later rules change also waited for the 15-minute poll. Found on the Flip4 on 29 Oct.
- The coalesced path now publishes on the device channel and sends the FCM wake, like a new row does.
  Duplicates cost nothing: the wake uses collapse key `wake`, and the agent drains the queue rather than
  acting on the message.
- Test: `push.test.ts` enqueues two coalesced `rules_updated` and asserts two wakes and no new row.
