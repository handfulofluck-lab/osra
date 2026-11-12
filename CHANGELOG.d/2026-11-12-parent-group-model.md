### Parent app — reads the iPhone's app groups and keeps the parent's group blocks on every save (5.5 PR B3c, part 1)
- `RuleSet.appGroupRules` (`AppGroupRule`, `block` only) is read, written in every PUT body, and carried by the
  rules editor's five draft rebuilds (and the new `RuleSet.copyWith`), so a save from any screen keeps a group
  block. The alerts and social screens already round-trip through `fromJson`/`toJson`.
- `DeviceSetup.groups` (`AppGroupReport`: id, label, counts) is read; null until the phone reports any.
- No screen changes yet: the group rows and their block switch are part 2.
- New `app_group_model_test.dart` (7 rows).
