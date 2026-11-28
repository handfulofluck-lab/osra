### Parent app — the bell badge refreshes when a push wakes the app or the app resumes (#1056)

Karim's report: the red count on the dashboard bell sometimes took a long time to appear, while opening the alerts feed showed the new notifications straight away. The count was refreshed only on a realtime `alert` frame, so any signal that did not arrive through the open socket left it stale until the feed was opened.

Now:

- **Foreground push:** reads the count immediately and once more 3 s later — the same bounded second read the realtime frame uses, because a push can be sent before its alert row is committed. **Cost: 2 `GET /v1/alerts` per push.**
- **Resume:** reads once when the app returns to the foreground and starts the fallback poll. **Cost: 2 reads per resume** (the immediate one plus the bounded second).
- **Fallback poll:** one read every 120 s while the app is foreground, stopped on pause. **Cost: 30 reads/hour/parent in the foreground, zero in the background.** The socket stays the primary path; this covers a socket that died without reconnecting, or a row committed after its frame.
- **Background push:** cannot refresh this state. It is handled in a separate isolate that posts a local notification and has no access to the widget tree, so the chain is "push posts the notification, resume refetches" — which is why the resume path is not optional.

The interval and the three triggers are pinned in `test/alerts_badge_refresh_test.dart`, and the wiring has its own row in `test/app_wide_refresh_test.dart` (mutant: leave the app-wide provider refreshing social events only — the state the issue reports).

Not verified where written: no device run, and the cost figures are request arithmetic, not a measured battery or radio profile.
