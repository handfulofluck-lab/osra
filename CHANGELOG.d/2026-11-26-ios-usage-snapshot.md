### OSRA Kids iPhone — the shape of one reported usage day (#1046)
- The child can now hold one day of iOS app usage in the app group: which app, how many minutes, which day. Only
  apps a parent selected in Screen Time can appear, because iOS exposes no installed-app inventory.
- The rules keep a report small and honest: sub-minute and unnamed rows are dropped, one app reported in pieces is
  one row, the list is capped at 20 and ordered longest-first, the day follows the child's calendar, and **an empty
  day is not reportable** — "nothing selected or the phone was off" must never reach a parent as a zero.
- Nothing is uploaded yet: the report extension that produces these numbers is the next step, and needs a device row.
