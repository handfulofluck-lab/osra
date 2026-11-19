### Android web filter — a parent's blocked site is sunk before any rewrite (#825)
- On the Flip4 (15 Nov) the parent blocked `youtube.com`, but Chrome in Restricted Mode still opened
  YouTube: `DnsFilterPolicy.decide` applied the SafeSearch / YouTube rewrite before the explicit
  blocked-domain check, so `www.youtube.com` became `restrict.youtube.com` instead of being sunk.
  Restricted Mode is `strict` by default, so every parent who blocks YouTube hit it.
- A parent's block (explicit domain or blocked category) now runs before the rewrites; only an explicit
  allowed domain outranks it. `DnsFilterPolicyTest` pins both directions: blocked `youtube.com`,
  `google.com` and `bing.com` sink while the rest of the rewrite still applies to unblocked hosts.
