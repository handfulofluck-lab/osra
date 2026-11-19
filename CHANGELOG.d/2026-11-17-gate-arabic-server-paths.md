### Merge gate — the server's own Arabic copy now needs the Arabic Bureau's line (#846)
- Five server files hold Arabic a parent reads and matched no path the gate watches: `lib/consentCopy.ts`
  (the sign-up consent), `lib/htmlPage.ts`, and the `linkPages`, `account` and `digests` routes. The consent
  text merged in #875 **with a dead Arabic link and no Bureau read**, which is what this closes.
- Mutant: removing the `consentCopy.ts` pattern fails the new row — measured, 1 of 294 red; restored 294 pass.
- **Trade-off, stated:** `account.ts` and `digests.ts` also carry logic, so a change there that touches no
  Arabic will still ask for the line. The Bureau can answer with a review that says so; there is no Arabic
  waiver in the gate today, and inventing one is not this PR's call.
