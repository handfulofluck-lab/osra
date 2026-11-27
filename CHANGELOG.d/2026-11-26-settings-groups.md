### Parent app — a grouped Settings list with the current value on every row (#1179, P-22)
- Settings is now one plain list of three groups: language and appearance, security, account. Each row
  carries its current value and opens the screen it belongs to.
- Two-step verification shows On or Off, and the recovery-codes row appears only while it is on.
- Sign out signs out this device; sign out of all devices revokes every session for the account and then
  signs this device out too. There is no Parent PIN row: the phone lock is the only app-level unlock.
