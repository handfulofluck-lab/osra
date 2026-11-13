### QA — the iPhone removal-attempt list for SC-5.5 (#669 part 1)
- New `docs/QA/IOS-REMOVAL-ATTEMPTS.md`: 18 things a child might try on an iPhone running OSRA Kids (delete or
  offload the app, Screen Time and restriction changes, the Apple Account, date and time, location, network,
  force-quit, other ways into a blocked app, VPN or profiles, erase or restore, re-pairing, an older build). Each row
  gives what should happen, how the test bed observes it on the phone or the server, and whether it may run there.
- Four rows are marked NOT RUN on the test bed because they change the Apple Account, the date or time, or need
  the device passcode. They are recorded with their expected result.
- `SCENARIO-SUITE.md` SC-5.5 links to the list.
