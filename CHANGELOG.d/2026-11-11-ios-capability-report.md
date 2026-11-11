### iOS child agent — sends its capability report, app groups included (5.5 PR B2, ADR-0034 A6, ADR-0037, #372)
- Every grant upload (launch, each app open, an authorization change, a Screen Time approval, a change to the app
  groups) now carries the capability report: the build (`child-ios`, version, build, `dev`/`testflight`/`appstore`),
  the three iOS grants (`family_controls`, `location`, `background_refresh`), the features (the six with no iOS API
  as `not_supported`), and the app groups as id + label + counts. The upload also sends `X-OSRA-Client`.
- Labels are cleaned again before they go out, Unicode direction controls included; a group with a bad id or an
  empty label is left out rather than costing the report; at most 20. Unreadable groups leave the field out, so the
  server keeps the last ones. New `CapabilityReportTests`.
- Needs PR B1 (#566) on the server first: before it, a report with `groups` is refused by the strict schema.
