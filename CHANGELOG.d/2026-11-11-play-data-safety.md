### Docs — the Play Data safety answers, mapped from the code (osra-security#8 F5, roadmap 5.2)
- New `docs/store/play/data-safety.md`: the Data safety form for the child agent's Play build and the parent
  app, one row per data type, each with the `file:line` that makes the answer true, checked against `main` at
  `5d3e49c`.
- **Deletion is now answered Yes.** The parent app's menu has Delete account (#442), and
  `/v1/account/delete` is the web link Play asks for. The production host for that link is still to confirm.
- **The capability report is declared** under App info and performance, Diagnostics, with the device model and
  OS version sent at pairing (ADR-0034).
- **Retention read from the code:** location 30 days, flagged excerpts and activity 90 days, daily totals
  365 days, and alerts with no expiry.
- Owner and lawyer decisions stay marked OPEN, with a list for Karim at the end.
