### Probe — a guardian without the permission gets no alert or location frame on the live socket (plan 2.7, #402)
- New `Q6f` covers the live-stack half of ADR-0014 amendment decision 3, built in #404. The no-permission
  guardian and the co-parent each open `/v1/ws`. Then an alert is raised for their family's child and the
  child's device sends a location ping. The co-parent's socket must receive both frames: it's the control,
  so "the guardian saw nothing" means something. The guardian's socket must receive neither.
- Measured on a local stack:
  - on `main` before #404 it fails as expected, 194/1 (`guardianGot=["alert","location"]`);
  - on `main` with #404 it passes, 195/0;
  - with the fan-out filter forced off it goes red again, 194/1.
- `docs/QA/security/authz-matrix.md`: the `GET /v1/ws` line and the probe-section closure list cite Q6f.
