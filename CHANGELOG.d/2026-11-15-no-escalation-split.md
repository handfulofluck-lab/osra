### Infra — deployer no-escalation policy attached without waiting for Identity Center (#766, #637)
- The Identity Center write denies move out of `osra-agent-no-escalation` into a new policy, `osra-agent-identity-center-stays`. That policy is still attached only after Karim's Identity Center access exists.
- `osra-agent-no-escalation` no longer depends on Identity Center, so the next org-audit apply attaches it even if the Identity Center steps fail (Fable on #637).
- The new policy is part of the protected deny set: the deployer cannot detach it, version it or delete it. The tests check that the split stays in place.
