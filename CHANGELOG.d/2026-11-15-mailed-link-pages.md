### API — the links in our mails open a page (#789, gate #637)
- Password reset, family invitation, MFA reset (confirm and cancel) and the digest's "open the dashboard" link each
  pointed at a path nothing served, so in production a parent who forgot their password received a link that opened
  nothing. The API now serves those pages itself (`services/api/src/routes/linkPages.ts`), in English and Arabic, the
  way it already serves account deletion.
- Opening a link changes nothing; each change sits behind a button (a POST), so a mail scanner cannot confirm or
  cancel anything. The reset and MFA reset pages call the existing `/v1/auth` routes in-process, so there is one
  implementation of each change and the auth rate limit counts the person's own address.
- Invitations can now be accepted from the mail: the page asks for the invited account's password (and authenticator
  code when two-step sign-in is on). The accept logic moved into `acceptInvite`, shared with
  `POST /v1/family/invites/:id/accept`, whose behaviour is unchanged.
- The page helpers moved from `routes/account.ts` to `lib/htmlPage.ts`, unchanged.
- Tests: `services/api/test/link-pages.test.ts` (19 rows, each naming its mutant).
