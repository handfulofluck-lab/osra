### Android child agent — queued social captures reach the scanner (#962)
- Fixed the delayed flush cancelling its own coroutine before the first suspending database call, which left captured rows queued with zero upload attempts.
- Caller cancellation now propagates instead of being mistaken for an empty queue; durable retry and per-row batch settlement are unchanged.
- JVM regressions cover delayed enqueue through batch POST and row deletion, plus cancellation with the row retained. Physical-device replay and installation remain pending an approved queued-data disposition.
