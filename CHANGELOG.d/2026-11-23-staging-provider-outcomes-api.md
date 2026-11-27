### Staging synthetic scan attribution (#962)

- An opted-in staging comparison retains a content-free result for each selected provider. Parent alert metadata names each model that flagged the scan and includes the score it assigned to each flagged category. A benign result or unavailable provider remains available for the approved staging test readback.

Staging OSRA-only inference uses a ten-second API deadline within the child request budget (#1007).
