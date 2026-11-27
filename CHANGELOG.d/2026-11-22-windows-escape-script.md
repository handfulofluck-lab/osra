### Windows — the child-escape rows as one script (#738)

`scripts/hardware/windows-escape.ps1` runs catalogue rows WN02, WN03, WN05–WN09, WN11, WN13 and WN14 on the
staging Windows test host as the child's **standard, non-elevated** account, printing `PASS`, `FAIL`, `SKIP`
or `UNKNOWN` per row with its evidence. It refuses to run from an elevated shell (exit 2), needs
`-AllowMutating` for the two rows that would change the machine, and reports a row that threw as `UNKNOWN`
so a harness error cannot look like a pass. `-SelfTest` exercises the refused/not-refused classifier and the
elevation guard.

A run on a Windows 11 machine with no OSRA installed produced `10 total, 3 PASS, 0 FAIL, 7 SKIP,
0 UNKNOWN` — the seven SKIPs are the rows whose claim needs the installed agent (tray restarted by the
service, the filter holding, the PIN dialog). **That run is not staging evidence**; it shows the harness
measures what it claims. A staging run needs PC Claude's Windows slot.

Tests only: no product code, no user-visible behaviour, no copy.
