### Architecture — phones report what they can enforce, and every app names its build (ADR-0034, roadmap 5.8)
- ADR-0034 designs the two open 5.8 items ADR-0028 named: a capability report (grants and features) on the
  existing telemetry upload, computed by the agent's own acknowledgement policies, and an `X-OSRA-Client`
  header with a version gate that blocks an old parent app (426) but only warns about an old child agent.
- A command the phone's fresh report says cannot work is recorded failed at once, as a refused `locate_now`
  already is (#221); a stale or `degraded` report never refuses anything.
- Request shapes of the last two released builds stay accepted, proved by recorded fixtures in CI.
