### Parent app — a parent can delete their account from the app (#442 PR 2)
- **What was missing.** Play requires an app that creates accounts to let them be deleted from inside it.
  `DELETE /v1/family` and `DELETE /v1/me` have existed since #464; the app never called them, so a parent
  could only delete an account from the web link (#467).
- **Two deletions, chosen by role.** The owner deletes the whole family; a co-parent or guardian deletes
  only their own account and the family carries on. The scope comes from the role, because offering the
  other one would offer an action that can only fail (`owner_role_required`, `owner_must_delete_family`).
- **Deliberately slow**, like the consent withdrawal: the copy states what is deleted, and the button stays
  disabled until the parent types **their own email**, compared after trimming and lower-casing both sides.
- **The password is required even though the shared re-auth dialog accepts a code alone.** #464's
  `ReauthSchema` is `{password, mfaCode?}`, so a code-only submit would come back as a `401` the parent
  could not read as "you left the password blank".
- **A `null` overview shows a spinner and never either copy**, and a *failed* overview shows the sentence
  plus a Retry rather than a spinner forever. The email and the role both come from that one overview, so
  the account asked about is the account acted on.
- Every refusal has a sentence: `reauth_failed`, `mfa_reenroll_required`, `consent_records_held`,
  `owner_role_required`, `owner_must_delete_family`, plus a fallback that keeps the status and code.
- 22 strings, English and Arabic. The Arabic is Claude's table; Karim is reviewing it, and a strings-only
  follow-up will carry any changes because nothing in the screen depends on the wording.
