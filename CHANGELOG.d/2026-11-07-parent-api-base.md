### CI — the parent app's store build can carry OSRA's server address (5.2)
- `parent-app.yml` passes the repository variable `OSRA_API_BASE` to `flutter build appbundle` as
  `--dart-define=API_BASE`, which `server_provider.dart` already reads as the built-in server.
- Unset keeps today's behaviour (the parent types an address); a value that is not `https://` fails the
  job, because the release build refuses cleartext.
