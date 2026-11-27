### Parent app — a grouped Settings list, and signing out everywhere asks first (#1179, P-22, #1204)
- Settings is now one plain list of three groups: language and appearance, security, account. Each row
  carries its current value and opens the screen it belongs to.
- Two-step verification shows On or Off, and the recovery-codes row appears only while it is on.
- There is no Parent PIN row: the phone lock is the only app-level unlock.
- Sign out of all devices revokes every session for the account and then signs this device out. It asks
  first, because Cancel has to be one tap away on a row that reaches every phone the account uses.
- A revocation that **fails** keeps the phone signed in and says so, so the parent can retry. The push
  registration retired before the call is registered again, because a parent who could not sign out must not
  also stop receiving the family's alerts. Nothing is registered back when there was nothing to retire.
- With the P-22 switch on, the dashboard menu carries one Settings entry in place of the four links that now
  live inside it. "Privacy and data" stays reachable in both states, and so does the P-07 home's settings tab,
  which collapses the same four rows to one Settings row under the switch as well.
