### iOS child agent — shields the app groups the parent blocks from the parent app (5.5 PR B3b, ADR-0037)
- The synced ruleset's `appGroupRules` (PR B3a) are read as lowercased group ids, stored with the other rules
  (`rules.blockedGroupIds`, cleared on unpairing) and shielded **together with** the groups blocked on the phone:
  the two add up, the phone's own toggle still works offline, and the server can add a block but never lift one
  set on the phone. A rule for a group this phone does not have blocks nothing; a server before B3a sends none.
- The groups screen shows such a group as blocked, with its toggle disabled and "Blocked from the parent app".
- New rows in `RuleSyncTests` (3) and `AppGroupsTests` (2).
