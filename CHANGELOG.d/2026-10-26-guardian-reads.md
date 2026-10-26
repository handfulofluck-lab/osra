### Architecture — a guardian reads a child's alerts, places and activity only with the permission (ADR-0014 amendment, 2.7)
- Karim decided on 26 Oct that a guardian invited without a permission no longer reads what it covers:
  `alerts` for alerts, `location` for locations and geofences, and `social` for search, social and web history.
  Owners and co-parents are unchanged.
- Embedded copies (geofences in `GET /v1/family/me`), pushes and live events follow the same rule. The family
  export becomes owner-only.
- This is the decision only. Kimi implements it and Ahmed updates the probe and the matrix. The amendment lists
  the tests the implementation owes.
