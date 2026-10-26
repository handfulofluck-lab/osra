### Security — realtime frames follow the guardian's permissions (ADR-0014 amendment decision 3, #402)
- The websocket ticket now carries the **parent** as well as the family (`{ familyId, parentId }`), parsed with a
  fallback to the old bare string so a deploy mid-connection does not close every socket.
- The gateway resolves a subscriber's role and permissions **once, at connect**, and the fan-out drops `alert` and
  `location` frames for a guardian that lacks `alerts` or `location`. Owners and co-parents are unchanged, and an
  event type the gate does not name is open by default rather than silently withheld.
- A database failure while resolving the gate leaves the socket **open**: the ticket already proved a live parent
  session, and a transient error must not become a new way to lose the stream.
- Tests: `realtime.test.ts` gains two rows — a guardian with only `location` receives `ready` and `location` but not
  `alert`, and a guardian with `alerts` plus a co-parent with none both receive it. Mutant: forcing the gate open
  fails exactly the first row.
