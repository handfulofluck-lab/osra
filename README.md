# UI/UX Review Frames — PR #1003 (`7575da55edb77862d76e70a6f52db5643a0308e8`)

- **PR:** `#1003` (`codex/830-parent-insights-freshness` — Parent Insights refresh, missing per-app breakdown copy, explicit zero vs omitted wellbeing ring, disabled daily limit)
- **Exact Head SHA:** `7575da55edb77862d76e70a6f52db5643a0308e8`
- **Capture Surface:** Real Flutter widget render surface (`AppTheme.light` / `AppTheme.dark`, synthetic `FakeApiClient`, `390x844` logical px @ `2.0x` DPR = `780x1688` PNG, `TextScaler.linear(2.0)` / 200% text, zero layout overflow exceptions).
- **Matrix:** 3 states (`01_reports_missing_breakdown` [22m total, empty `topApps`, Refresh button], `02_reports_empty` [0m], `03_dashboard_zero_vs_omitted` [Alex score 0 ring, Sam omitted score]) × 2 locales (`en` LTR, `ar` RTL) × 2 themes (`light`, `dark`) = **12 frames**.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `ar_dark_200pct_01_reports_missing_breakdown.png` | 97929 | `1e154128cb9f44d2e5b18ec74b45e4de2e81b27fd72b788523e58373ed9b07e6` |
| `ar_dark_200pct_02_reports_empty.png` | 30592 | `76ad8fac85393eda443987cc695dafe151e64f2db3c539013cd32a487f2316b8` |
| `ar_dark_200pct_03_dashboard_zero_vs_omitted.png` | 91557 | `94f277fc116a07ceb15edc4e37d247a4ac213d831ed0f2a5714276d8294949e4` |
| `ar_light_200pct_01_reports_missing_breakdown.png` | 96878 | `cde4538cf043e037d0ac615bec2b9cf4e518cd04989b973aaa428c4f3cd5d8fa` |
| `ar_light_200pct_02_reports_empty.png` | 30430 | `4040e21126f43098dd90786b2caa12d43d67135328ecae3c52e59c05fad0a707` |
| `ar_light_200pct_03_dashboard_zero_vs_omitted.png` | 90335 | `d4d37e5a006466904d27752f01068d3bd53454caa331cb86ce98d5f9b93c127e` |
| `en_dark_200pct_01_reports_missing_breakdown.png` | 108325 | `597029567390b292dc403ca5758a1d34dd8ea23577ddf1521d711f7b155435e3` |
| `en_dark_200pct_02_reports_empty.png` | 37727 | `b145c6cb95adbb3ced5a876144cba5b5aa9d47e3ce012000a992b151b4886b02` |
| `en_dark_200pct_03_dashboard_zero_vs_omitted.png` | 92511 | `3cefcac1a82d333115fdbf9bcd9d63edbe1ea757e0c2153d4e08ec2653248be0` |
| `en_light_200pct_01_reports_missing_breakdown.png` | 108021 | `c5e73211b6d50442cd8f098477c84bee12199b8c6b78e710ce7033ac23767820` |
| `en_light_200pct_02_reports_empty.png` | 37609 | `dcfb51b69ef6be269006d58c2621fb75dfb199d78353b100e6ef16ac81040e1c` |
| `en_light_200pct_03_dashboard_zero_vs_omitted.png` | 92602 | `49ef008bd5f5e9b3690c9c3c4a9cdc9cf13ff26dc5666f3e8a82a161b3a9633e` |
