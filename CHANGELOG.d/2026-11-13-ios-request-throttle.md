### OSRA Kids for iPhone — "Request access" asks once per app every few minutes (#744)
- **Before:** each tap on the shield's "Request access" sent the parent a new alert. Ten quick taps sent ten alerts
  in 17 seconds and buried the real request.
- **After:** one request per blocked app, website or category every 5 minutes (`ShieldTapPolicy.shouldSendRequest`,
  times kept in the app group under an opaque token key). Further taps keep the shield up and send nothing. With no
  app group the request is still sent, so it is never lost to storage.
- Rows (`ShieldTapPolicyTests`): a repeat inside the window sends nothing, a request after the window sends, other
  targets are separate, ten taps in 17 s send one, no app group still sends, and a source row keeps the delegate's
  alert behind the throttle for apps, websites and categories alike.
- Not in this PR: the "already asked" line on the shield (#677, with the Bureaus) and the server-side duplicate
  guard (#744's API half).
