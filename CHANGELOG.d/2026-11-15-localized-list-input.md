### Parent app — localized separators in rule and digest lists (#794)
- Allowed and blocked domains, routine blocked and allowed apps, and digest recipients accept Latin and Arabic comma/semicolon separators and line breaks; items are trimmed and empty items are dropped.
- Domain fields remove LRM/RLM/ALM direction marks before their existing validation. Digest recipients keep those marks so the API's existing email validation still rejects them.
- No user-facing wording changed. Arabic-device evidence is not claimed here; the requested phone or simulator picture remains a separate verification row.
