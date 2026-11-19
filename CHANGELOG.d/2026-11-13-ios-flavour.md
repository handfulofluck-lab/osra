### OSRA Kids for iPhone — a developer-signed build reports flavour `dev` (#693)
- **Before:** a Release build signed by a developer and installed on a phone reported `testflight`, because it
  has a sandbox receipt path. ADR-0034 A7 picks the APNs host by flavour, so such a build would get the
  production host.
- **After:** a build that still carries `embedded.mobileprovision` (developer or ad hoc signing) reports `dev`.
  Only a build without one, which App Store and TestFlight signing produces, is told apart by its receipt
  (`testflight` or `appstore`).
- Rows (`CapabilityReportTests`): debug, developer-signed Release, ad hoc, TestFlight, and App Store, each with its
  flavour.
