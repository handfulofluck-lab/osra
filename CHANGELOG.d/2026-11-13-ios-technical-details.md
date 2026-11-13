### OSRA Kids for iPhone — the server address moves under "Technical details" (#661)
- **Before:** the Status screen showed the server URL near the top, which reads as technical to a child or a parent
  and kept the screen out of the store screenshots. The child and device ids were already gone (#645).
- **After:** the server address is in a collapsed **Technical details** section (Arabic «التفاصيل التقنية»,
  approved by Karim on 13 Nov) at the bottom of the screen, closed until tapped. Sync now and the last-synced line
  stay where they were.
- Rows: `SyncStatusTests` pins the section as closed by default, last on the screen, and holding the only server
  row, with the English and Arabic lines present. `A11yID.statusTechnicalDetails` is added, and the identifier
  scan now also covers `DisclosureGroup`.
