### API — a WebSocket publish and its fan-out are now visible in the log (#350)

A realtime delivery miss used to be unattributable: `publishFamilyEvent` dropped `PUBLISH`'s return
value, and the gateway's subscriber installed `on("error", () => {})`, so a reconnect window — the
likeliest way a frame is dropped — was silent by construction. Three lines now close that gap, all
through the Fastify logger the API already writes with, and all carrying only `familyId`, the event
`type` and counts:

```
{"level":30,"familyId":"fam-1","type":"alert","receivers":0,"msg":"realtime publish"}
{"level":30,"familyId":"fam-1","type":"alert","listening":true,"written":0,"sockets":2,"msg":"realtime fan-out"}
{"level":30,"familyId":"fam-other","type":"alert","listening":false,"written":0,"sockets":0,"msg":"realtime fan-out"}
{"level":40,"err":{…},"subscriberErrors":1,"msg":"realtime subscriber error (ioredis reconnects; sockets unchanged)"}
```

`receivers` is `publish()`'s own return value, so `receivers: 0` reads as "the route answered 201 and
the event reached no one" — the state the 2026-10-23 investigation could not see. `written` counts the
frames actually sent and `sockets` the set's size, so a `CLOSING`/`CLOSED` socket shows up as the
difference; `listening: false` is "nobody subscribed to this family", not "wrote 0 of 2". No payload,
no ticket, no id and no address is logged. `subscriberErrorCount()` exposes the in-memory error count;
it resets on restart and is not yet on any endpoint.

Tests: `services/api/test/gateway-evidence.test.ts`. Mutants that make them fail are stated beside each
test (a constant for `receivers`, `set.size` for `written`, the old `() => {}` handler, and a dropped
`listening: false` line) and were each run against the suite.

— Kimi Code (development lead)
