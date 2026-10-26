### Security — realtime frames follow the guardian's permissions (ADR-0014 amendment decision 3, #402)
- The websocket ticket now carries the **parent** as well as the family (`{ familyId, parentId }`), parsed with a
  fallback to the old bare string so a deploy mid-connection does not close every socket.
- Owners and co-parents are settled once, at connect, before the socket joins the fan-out. For a guardian (or a socket
  whose reader is unknown, such as a legacy ticket) the gateway reads the parent row **on every gated frame**, so an
  owner removing `alerts` or `location` takes effect on the next frame, not on reconnect.
- The check **fails closed**: a database error or a legacy ticket withholds `alert` and `location` frames, while
  ungated frames (`ready`, `consent_revoked`) still flow and the socket stays open. A parent row that no longer exists
  closes the socket with 4001. An event type the gate does not name is open by default.
- Tests: `realtime.test.ts` gains five rows (guardian with only `location`; guardian with `alerts` plus co-parent with
  none; revocation on an open socket; DB error withholds the gated frame but not `consent_revoked`; missing parent row
  closes with 4001). Mutants R1-R4 each turn their row red; live probe Q6f (Ahmed's follow-up) 195/0.
