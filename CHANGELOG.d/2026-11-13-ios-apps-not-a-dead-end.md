### An iPhone child no longer meets a picker that cannot list its apps (#643)
- **Before:** the Rules editor's Apps tab offered **"Choose from child's apps"** to every family. On an iPhone
  child it opened a picker with nothing in it, because iOS never reports an app list to us — a dead end with no
  way forward, and the sentence beside it named Samsung Pay and Google Wallet, which are Android package ids
  OSRA can see only on Android.
- **After:** for an iOS child the picker is replaced by the path that works — the approved sentence from #583,
  *"Groups are made on the child's iPhone, behind the parent PIN. Block one here and the iPhone shields its
  apps."* — and the Android payment example is hidden, because on that phone OSRA never learns app names; the
  parent blocks a group instead. An Android child sees exactly what it saw before.
- **No new Arabic.** Both sentences are existing approved strings (`appGroupsBody`, `bedtimeBlocksPayments`), so
  this change needs no Bureau line — the reason it could ship the same day.
- **Row:** an iPhone-child fixture asserts the picker and the payment example are absent and the explanation is
  present; deleting both guards reds that row, and the Android rows above it stay green.
