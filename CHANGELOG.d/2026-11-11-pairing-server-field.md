### Child agent — pairing no longer asks a child to type a server address the parent cannot show (customer guide G4)
- **Before:** the pairing screen asked for a server URL. A parent's screen shows only six digits, so the address
  had to be typed by whoever held the phone — and a store build accepts `https` on `osratech.com` only, so a
  wrong address was a dead end rather than a fallback.
- **After:** `PairingServerFieldPolicy` decides the field from three sources, in order: a **scanned QR** (locks
  both fields, as before), then the **build's own server** (`BuildConfig.API_BASE`, set with `OSRA_API_BASE` or
  `-Posra.apiBase` at build time — the same repository variable the parent app uses), then whatever the tester
  typed. A build with no server keeps today's editable field, so local testing against a LAN backend is
  unchanged.
- **A locked field is never empty**: a blank or whitespace `API_BASE` falls through to the editable field rather
  than locking an address nobody can fix — the row that pins it is the one that would have shipped otherwise.
- The six-digit code stays editable unless a QR supplied it: a built-in server carries no code, and reading six
  digits off the parent's screen is the one thing a person must still do.
- Rows: `PairingServerFieldPolicyTest` (6). Deep link, QR and the release network config are untouched.
