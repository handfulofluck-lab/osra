# Live pre-test checklist

**No live test starts until every check below is green for every child device in the session.**

The preflight runs only inside the staging scope and phone lease already approved for this session. Row 4's audible Ring needs Karim's own current words for that Ring (a relayed or GitHub request is not enough) and the family is told before it rings.

The test coordinator starts this checklist one hour before the session, fills in one column per child device, and posts the completed record on [status issue #50](https://github.com/handfulofluck-lab/osra/issues/50) before testing begins. A red, unchecked, or evidence-free row stops the start; it is not a note to investigate after messages have been sent.

Do not attach message text, contact names, credentials, or other private family data to the public record. Link to non-sensitive evidence such as build numbers, event IDs, model/configuration versions, timestamps, and yes/no readbacks.

## Required checks

| # | Check | Required evidence for each child device |
|---|---|---|
| 1 | **AI scores a message end to end** | One synthetic message is scored by the model through the real capture-to-result path. Record the non-sensitive event/result ID and model or serving configuration; a local classifier-only result does not satisfy this row. |
| 2 | **Monitoring is saved ON for every app under test** | Read the settings back from the API before the first message. Record the app keys and enabled/disabled state; do not rely on the parent screen's last known state. |
| 3 | **Every child runs the same assigned build** | Read back `versionName` and `versionCode` on each phone and compare them with the build assigned to the session. Record the source SHA or artifact identifier as well. |
| 4 | **Each parent can receive an alert and stop a ring** | Deliver one test alert to every participating parent app, then issue Ring and Stop from that parent app. Record delivery and stop acknowledgements, and confirm no ring remains active. |
| 5 | **Alarm levels in effect are known per language** | Record the active rule/model version, cut-offs, effective date, and language coverage. The evidence must describe the configuration actually serving the test, not only a configuration file in a branch. |
| 6 | **The child is online, setup is complete, and Pause works** | Confirm the child reports Online with setup complete, then issue Pause and verify it takes effect on that device. Resume immediately after the check and record the restored state. |
| 7 | **Notification access is ON and both closed-chat and open-chat WhatsApp captures alert** | On every child phone running the Full build, confirm OSRA's notification listener is enabled (read back `enabled_notification_listeners`), and verify that one incoming WhatsApp test message with the chat **closed** and one with the chat **open** each raise a parent alert (`osra-security#78`). Record non-sensitive event/alert IDs only. |
| 8 | **Build receipt, lab signer, and upgrade-over-paired gate** | Before build links go out, verify each APK's `versionCode` is strictly higher than the installed build (Child Full `>= 90`, above cable build `89`; Parent `> 1406`), lab signer matches `2ecc2def…`, APK SHA-256 is recorded, and `testOnly=false` (plus `aps-environment` match for any iOS build). If an upgrade fails, keep the installed build and never uninstall. |

## Why this gate exists

- [#1144](https://github.com/handfulofluck-lab/osra/issues/1144): a test is not meaningful if the assigned model did not actually score the message end to end.
- [#1142](https://github.com/handfulofluck-lab/osra/issues/1142): a visually enabled toggle is insufficient; monitoring state must be present in the server-side rule set and read back before capture is tested.
- [#1130](https://github.com/handfulofluck-lab/osra/issues/1130): a freshly installed child can otherwise run without rules until a parent saves something, leaving protection and Pause dependent on an unrelated action.

These checks catch those false starts before a tester spends a session interpreting missing alerts, stale rules, or different builds as product behavior.

## After the session

Follow [the testing guide](../TESTING.md) and [the device lease rules in AGENTS.md §9](../../AGENTS.md): clear Pause/Ring and every other restriction, remove test artifacts and forwards as required, release the phone lease with an honest final state, and delete only test-owned server data. The completed checklist is a start gate, not a substitute for cleanup or independent verification.
