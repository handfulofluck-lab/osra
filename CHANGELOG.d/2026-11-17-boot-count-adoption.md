### API — the boot counter is adopted on the first tick that carries one (#884 review follow-up)
- A stored `lastBootAt` with no `lastBootCount` is an agent that was upgraded in place. The tick that first
  carries a count now records it **silently** (new kind `same_boot_adopt_count`): no alert, and `lastBootAt`
  is not rewritten, because this is not a new boot and moving the instant would misdate the next gap. Without
  it, the count-less fallback kept the clock-move weakness for a full uptime; with it the weakness ends after
  one tick.
- The restart alert's dedupe key (`boot|<iso>|<count>`) has a row again — it was lost when the key gained the
  count, and it is what stops two API instances deciding "new boot" for one restart from pushing twice.
- Verified: `npx vitest run test/boot-report.test.ts test/devices.test.ts` **67 passed**, with the two new rows
  watched failing against the old behaviour first (**2 failed | 65 passed**), and re-run after rebasing onto
  `main` (`1d61b9f4`).
