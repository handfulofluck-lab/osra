### Parent app — the server is locked in store builds (osra-security#8 F3)
- A build with `API_BASE` built in (the store builds) talks to that server only, the rule the child agent got in
  #553. The login screen's Server field shows it read-only, a typed or previously saved URL is ignored, and a
  background wake uses it too. Builds without it (local testing) keep the editable field.
- New `isServerLocked`, `builtInServerUrl` and `effectiveServerUrl` in `server_provider.dart`;
  `ServerUrlNotifier` and `resolveBackgroundBaseUrl` take the built-in value as a parameter for the tests.
- A signed parent-app release build on main (the store bundle) now fails when `vars.OSRA_API_BASE` is unset,
  since an unlocked field is what F3 is about. A pull request's signed bundle gets a warning; unsigned builds
  keep the notice.
- New `server_lock_test.dart` (8 rows).
