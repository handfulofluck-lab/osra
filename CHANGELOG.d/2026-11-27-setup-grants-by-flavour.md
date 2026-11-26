### API — Full phones are protected only after notification access, and setup sends one parent notice (#1208, osra-security#82)
- The server now asks for the same grants the phone does: Full builds need notification access as an
  eighth required grant, Play builds keep their seven. Protection and "Phone is protected" arrive only
  when the last one is granted.
- Pairings that already completed keep their completion: the new rule never reopens them.
- The phone's immediate "setup not complete" notice and the server's 30-minute reminder now share one
  key per pairing (`setup_incomplete:<deviceId>`). Whichever comes second refreshes the same row instead
  of paging the parent again, and a notice still queued on the phone after completion is dropped.
