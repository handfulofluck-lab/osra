### iOS child agent — sends its capability report, app groups included (5.5 PR B2, ADR-0034 A6, ADR-0037, #372)
- Every grant upload (launch, each app open, an authorization change, a Screen Time approval, a change to the app
  groups) now carries the capability report: the build (`child-ios`, version, build, `dev`/`testflight`/`appstore`),
  the three iOS grants (`family_controls`, `location`, `background_refresh`), the features (the six with no iOS API
  as `not_supported`), and the app groups as id + label + counts. The upload also sends `X-OSRA-Client`.
- Labels are cleaned again before they go out, Unicode direction controls included; a group with a bad id or an
  empty label is left out rather than costing the report; at most 20. Groups that cannot be read (the app group
  will not open, or the saved groups do not decode) leave the field out, so the server keeps the last ones; only
  truly no groups sends an empty list (`AppGroupStore.loadIfReadable`). New `CapabilityReportTests`.
- Live-API case 11: a report with one group is uploaded from the simulator, and the parent's `GET /v1/devices`
  shows that group's id, label and counts.
