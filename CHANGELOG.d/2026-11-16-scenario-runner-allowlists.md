### QA — scenario runner: package allowlist at run time, `content` removed, serial mandatory (#797)
- The package allowlist — `com.osratech.child`, `com.osratech.child.full`, `com.osratech.parent` — now
  applies when a command runs, not only when a manifest is validated: an `appops` target, a
  `pm clear`/`pm uninstall` target and the runner's own `-Package` must be one of the three. Matching is
  case-sensitive (`-cnotin`, and `-cne` against the original string), so an upper-case spelling of an
  allowed package is refused rather than silently folded.
- `manifest.schema.json` accepts only those three values for `package`, so a manifest naming anything else
  fails validation before a lease is claimed.
- The `content` command is removed from the ADB allowlist: only the first `--uri` was checked, so a second
  `--uri content://call_log/calls` could read the owner's call log. No scenario used it and no app in the
  repo declares a content provider. The `nonPersonal`/`projection` step fields that existed only for it are
  gone from the schema and the runner.
- `-Serial` has no default; a run that does not name the handset stops with `serial_required`. The five
  Pester suites and the `workflow-lint` dry run pass the serial explicitly.
- Tests: a manifest with an upper-case package and an `Invoke-ScenarioRun` call with `com.whatsapp` both
  assert `package_not_in_allowlist`, and the run row also asserts an empty fake-adb log and no lease claim;
  two-`--uri` content commands are refused. Verified locally with Pester on this tree; the physical device
  was not used.
