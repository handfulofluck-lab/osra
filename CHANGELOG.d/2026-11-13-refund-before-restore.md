### Tests — a refund before an expired purchase is restored (#700)
- Added a billing regression covering a voided notification for an unbound token followed by a restore whose Play state is expired. The restore is recorded through `revokeEntitlement`, never an active grant; the early notification is acknowledged and logged without a Play call.
- The test passes on the real route. A temporary mutant that treated expired purchases as active failed it and three existing billing cases; the production source was restored unchanged before the full suite.
