### CI — parent app pinned to Flutter 3.47.9
- **Before:** `parent-app.yml` installed whatever Flutter `stable` was current. Stable moved to 3.50.0 on
  2026-11-11; it deprecates `package:flutter/material.dart` in favour of `package:material_ui`, so
  `flutter analyze` reported a deprecation info in every screen and the parent-app job went red on every PR
  that touches the app (first seen on #559, run 43104598319), and on main's nightly run.
- **After:** both Flutter setup steps pin `flutter-version: 3.47.9`, the last stable that built main green
  (run 43083839765). Moving to `material_ui` and raising the pin is one follow-up change.
