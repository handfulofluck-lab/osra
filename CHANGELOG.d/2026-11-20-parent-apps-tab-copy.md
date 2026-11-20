### Parent app — the Apps tab says which phone it is talking about, and stops mentioning the PIN (#953)
- For a child with **both** an Android phone and an iPhone, the Apps tab now has two headings, "Android apps" and
  "iPhone apps", so a parent can tell which list they are looking at. A child with one platform sees no headings: with
  one list, a heading says nothing. (UI/UX Bureau U40.)
- The iPhone empty state no longer explains that groups are made "behind the parent PIN". It reads "No apps chosen
  yet" and names the step that works: open Osra on the child's iPhone and choose the apps there. (U42.)
- The rules editor's iPhone sentence now says where iPhone apps are managed and that the rules on that screen apply to
  Android apps only; the retired sentence was replaced in both catalogs in the same change.
- Under the group switches, one line states the trap plainly: turning a switch off here does not lift a block the
  phone set itself. (U40.)
- `appGroupsBody` is deleted from `app_en.arb` and `app_ar.arb`, because its Arabic also mentioned the PIN.
- Every string is the wording the two Bureaus approved (Arabic Language Bureau `7038515313` and `7038534975`, UI/UX
  Bureau `7038528676` and `7032920246`), transcribed without edits. The child's name is wrapped in a first-strong
  isolate so it stays in place inside an Arabic line.
