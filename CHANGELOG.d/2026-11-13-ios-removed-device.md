### OSRA Kids for iPhone — a phone the parent removes goes back to pairing (#690)
- **Before:** after the parent removed the iPhone from the family, OSRA Kids kept showing "Paired", kept the old
  rules and shields, and never returned to the pairing screen.
- **After:** the server's `device_revoked` answer on any device-token call (rules, commands, location and
  telemetry, push token) unpairs the phone. The pairing, rules, applied shields, unsent location and parent PIN
  are cleared (`DeviceRevocation.unpair`), and the Status screen switches to pairing after the next open or Sync
  now. Any other 401 keeps the pairing as before.
- Rows (`DeviceRevocationTests`): only `401 device_revoked` counts; each of the five call paths unpairs on it;
  another 401 keeps everything; and a source row fails if a file sends the device token without handling the
  answer.
