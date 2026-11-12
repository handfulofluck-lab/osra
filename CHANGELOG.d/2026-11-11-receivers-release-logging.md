### Android child agent — exported receivers confirm their broadcast; no HTTP logging in release (osra-security#8 F6, F4)
- `BootReceiver`, `PackageAddedReceiver` and `PackageReplacedReceiver` take only their own action, through the new
  `BroadcastGate`. The install alert is sent only for a package PackageManager says is installed and was first
  installed in the last 10 minutes. The "Agent updated" alert is sent only when our own package's last update is
  that recent.
- The OkHttp logging interceptor is attached only in debug builds, so a release build writes no request lines
  (which name the child and the device) to logcat.
- New `BroadcastGateTest` (8 rows) and `ReleaseLoggingWiringTest` (1 row). The four wiring rows fail on main's
  sources.
