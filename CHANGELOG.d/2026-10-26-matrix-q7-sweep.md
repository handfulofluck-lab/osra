### Authorization matrix — §1a cites the probe rows that already cover the remaining GAP cells (plan 2.7, docs only)
- 23 lines in `docs/QA/security/authz-matrix.md` §1a still listed cells as GAP that probe section Q already
  asserts. The changes:
  - **Device cells:** every device cell on a parent-only route now cites p:Q7, which walks all of them with
    a live device token.
  - **Co-parent and guardian refusals:** these now cite p:Q6 and p:Q6b on the routes in Q6's refusal list.
  - **Other family:** the cells on `/commands/history` and `GET …/consent` now cite p:Q8.
- What is still GAP is unchanged in substance:
  - other family on `PATCH /v1/family/children/:id`, `POST …/consent` and `PATCH /v1/rules/:childId`;
  - consent on `PATCH /v1/rules/:childId`;
  - the owner on the `/pause` and `/resume` aliases and on `GET /v1/me/push-tokens`;
  - co-parent and guardian on `POST`/`DELETE /v1/me/push-token`.
