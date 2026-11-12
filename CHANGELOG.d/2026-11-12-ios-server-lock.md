### iOS child agent — a store build pairs only with its own server (#634 gate item G1)
- `OSRA_API_BASE` (a build setting, written into Info.plist as `OSRAAPIBase`) is the store build's server. When it
  is an `https://` URL, the pairing screen shows it locked and the claim goes to it whatever the field holds; an
  unset or unexpanded value, or an `http://` one, is no server. Simulator and local builds set none and keep the
  editable field. The rule Android has since #553 and the parent app since #579.
- New `PairingServerField` and `PairingServerFieldTests` (5 rows).
