- #962 adds independent Bedrock and OSRA model outcomes to the private staging analyzer. Synthetic tests cover a scored peer surviving a failed peer and the common deadline. Private endpoint, device and Parent acceptance are pending.
- The staging analyzer can validate the in-process OSRA CPU service response, including model and calibration digests. Synthetic route tests cover flagged, harmless and mismatched responses.

The staging OSRA-only collector now allows nine seconds for CPU inference, bounded by approval expiry (#1006).
