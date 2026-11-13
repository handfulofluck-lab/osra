#!/usr/bin/env bash
# OSRA - Android child-escape probe (docs/testing/CHILD-ESCAPE-CATALOGUE.md, section 1 on Android).
#
# Plays the child: with a gate screen already up (ring, lock, block or the parent-PIN gate), it presses the keys
# and opens the system surfaces a child uses to get out, and after each one measures whether the gate is back on
# top within the budget and, for the ring, whether the alarm is still sounding and the agent's process is the
# same one. It does not send parent commands itself: start the gate first (parent app, or --trigger), run the
# probe, then clear the gate (parent app, or --clear). Every row prints PASS / FAIL with what was measured.
#
#   bash scripts/hardware/android-escape-probe.sh --serial R5CW116Y6GF --gate ring [--presses 10] [--out DIR]
#   bash scripts/hardware/android-escape-probe.sh --gate lock --trigger './send.sh lock' --clear './send.sh unlock'
#
# Works in Git Bash on the Windows host (adb.exe) and on Linux CI against an emulator.
#
# SAFETY (AGENTS.md section 9, docs/testing/CHILD-ESCAPE-CATALOGUE.md "Rules"):
#  - Hold the phone lease first (scripts/hardware/phone-claim.ps1 -Action Claim). Set OSRA_LEASE_HOLDER to your
#    name; the probe refuses to run on a physical device without it.
#  - This script never changes the clock, date or time zone, never calls dpm, never reboots, never types or
#    guesses the phone's own lock-screen PIN, and never enters the app's parent PIN (it only tries inputs that
#    must be refused).
#  - The power-key row turns the screen off and on. On a phone with a secure lock screen that needs the owner's
#    unlock afterwards, so it runs only with --with-power (book it with the maintainer on the Flip4).
#  - Wrong-PIN rows count as failed attempts on the gate (MAX 5 before lockout); the probe uses at most 3.
set -u

ADB="${ADB:-adb}"
SERIAL=""
GATE=""
PRESSES=10
BUDGET_MS=3000
OUT=""
TRIGGER=""
CLEAR=""
WITH_POWER=0
PKG="com.osratech.child"
EMULATOR_OK=0

usage() { sed -n '2,25p' "$0"; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --serial) SERIAL="$2"; shift 2 ;;
    --adb) ADB="$2"; shift 2 ;;
    --gate) GATE="$2"; shift 2 ;;
    --presses) PRESSES="$2"; shift 2 ;;
    --budget-ms) BUDGET_MS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --trigger) TRIGGER="$2"; shift 2 ;;
    --clear) CLEAR="$2"; shift 2 ;;
    --with-power) WITH_POWER=1; shift ;;
    --package) PKG="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

case "$GATE" in
  ring) GATE_ACT="com.familyshield.agent.commands.RingActivity" ;;
  lock) GATE_ACT="com.familyshield.agent.commands.LockActivity" ;;
  block) GATE_ACT="com.familyshield.agent.enforcement.BlockActivity" ;;
  pin) GATE_ACT="com.familyshield.agent.security.TamperGuardActivity" ;;
  *) echo "--gate must be ring, lock, block or pin" >&2; exit 2 ;;
esac

export MSYS_NO_PATHCONV=1   # Git Bash: keep /sdcard-style paths intact for adb
A=("$ADB"); [ -n "$SERIAL" ] && A+=(-s "$SERIAL")
sh_() { "${A[@]}" shell "$@" 2>/dev/null | tr -d '\r'; }

if ! "${A[@]}" get-state >/dev/null 2>&1; then echo "no device reachable through adb" >&2; exit 2; fi
if [ "$(sh_ getprop ro.kernel.qemu)" = "1" ] || [ "$(sh_ getprop ro.boot.qemu)" = "1" ]; then EMULATOR_OK=1; fi
if [ "$EMULATOR_OK" = 0 ] && [ -z "${OSRA_LEASE_HOLDER:-}" ]; then
  echo "physical device: claim the phone lease first and set OSRA_LEASE_HOLDER (AGENTS.md section 9)" >&2; exit 2
fi

[ -z "$OUT" ] && OUT="escape-probe-$(date -u +%Y%m%dT%H%M%SZ)-$GATE"
mkdir -p "$OUT"
RESULTS="$OUT/results.tsv"
printf 'row\tresult\tmeasured\n' > "$RESULTS"
FAILS=0

now_ms() { date +%s%3N; }
top_activity() { sh_ dumpsys activity activities | grep -m1 -E 'topResumedActivity=|mResumedActivity:' | sed -E 's/.* ([^ ]+\/[^ ]+) .*/\1/'; }
gate_on_top() { top_activity | grep -q "${GATE_ACT##*.}"; }
agent_pid() { sh_ pidof "$PKG" | awk '{print $1}'; }
app_uid() { sh_ dumpsys package "$PKG" | grep -m1 -oE 'userId=[0-9]+' | cut -d= -f2; }
UID_APP="$(app_uid)"
if [ -z "$UID_APP" ]; then echo "$PKG is not installed on this device" >&2; exit 2; fi
# An alarm-usage player owned by the agent in state "started" (dumpsys audio, playback configurations).
alarm_playing() {
  sh_ dumpsys audio | grep -E "u/pid:${UID_APP}/" | grep -E 'usage=USAGE_ALARM' | grep -q 'state:started'
}
alarm_volume() { sh_ dumpsys audio | awk '/- STREAM_ALARM:/{f=1} f&&/Current:/{print; exit}'; }

# Wait up to BUDGET_MS for the gate to be on top again; echo the time it took or "never".
wait_gate() {
  local t0; t0=$(now_ms)
  while :; do
    if gate_on_top; then echo $(( $(now_ms) - t0 )); return 0; fi
    if [ $(( $(now_ms) - t0 )) -ge "$BUDGET_MS" ]; then echo never; return 1; fi
    sleep 0.2
  done
}

PID0=""
record() { # row, ok(0/1), measured
  local r="PASS"; [ "$2" = 1 ] && { r="FAIL"; FAILS=$((FAILS+1)); }
  printf '%s\t%s\t%s\n' "$1" "$r" "$3" | tee -a "$RESULTS"
}
# After any escape: gate back in budget; ring still sounding; same process (a crash is never a way out, E18).
check_after() { # row label
  local row="$1" took ok=0 extra=""
  took=$(wait_gate) || ok=1
  extra="gate back: ${took}ms; top=$(top_activity)"
  if [ "$GATE" = ring ]; then
    if alarm_playing; then extra="$extra; alarm sounding"; else ok=1; extra="$extra; ALARM SILENT"; fi
  fi
  local p; p=$(agent_pid)
  if [ "$p" != "$PID0" ]; then ok=1; extra="$extra; PROCESS CHANGED ($PID0 -> ${p:-none})"; fi
  "${A[@]}" exec-out screencap -p > "$OUT/${row}.png" 2>/dev/null
  record "$row" "$ok" "$extra"
}

key() { sh_ input keyevent "$1" >/dev/null; }
tap_text() { # tap the first node whose text contains $1 (uiautomator); returns 1 if absent
  sh_ uiautomator dump /sdcard/osra-escape.xml >/dev/null
  local xml; xml=$(sh_ cat /sdcard/osra-escape.xml)
  local b; b=$(printf '%s' "$xml" | grep -oE "text=\"[^\"]*$1[^\"]*\"[^>]*bounds=\"\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]\"" | head -1 | grep -oE '\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]')
  [ -z "$b" ] && return 1
  local x1 y1 x2 y2; read -r x1 y1 x2 y2 <<<"$(echo "$b" | tr '[],' '   ')"
  sh_ input tap $(( (x1+x2)/2 )) $(( (y1+y2)/2 )) >/dev/null
}

# ---------------------------------------------------------------------------------------------------- start
if [ -n "$TRIGGER" ]; then echo "trigger: $TRIGGER"; bash -c "$TRIGGER"; fi
echo "waiting for the $GATE gate ($GATE_ACT) ..."
for _ in $(seq 1 60); do gate_on_top && break; sleep 1; done
if ! gate_on_top; then echo "the $GATE gate is not on top (top=$(top_activity)); start it first" >&2; exit 2; fi
PID0=$(agent_pid)
T0_DEV=$(sh_ date +%s)   # E18: any crash after this moment is a finding (osra-security#17 looked like an escape). Never clear the buffer: it is other runs' evidence.
echo "gate up; agent pid $PID0; app uid $UID_APP; alarm $(alarm_volume)"
[ "$GATE" = ring ] && { alarm_playing && record "pre-ring-sounding" 0 "alarm sounding" || record "pre-ring-sounding" 1 "alarm not sounding before any escape"; }

# E01 Home, N presses in a row
for i in $(seq 1 "$PRESSES"); do key KEYCODE_HOME; check_after "E01-home-$i"; done
# E02 Back, single and long
key KEYCODE_BACK; check_after "E02-back"
sh_ input keyevent --longpress KEYCODE_BACK >/dev/null; check_after "E02-back-long"
# E03 Recents, then Home from Recents
key KEYCODE_APP_SWITCH; sleep 1; check_after "E03-recents"
key KEYCODE_APP_SWITCH; sleep 1; key KEYCODE_HOME; check_after "E03-recents-then-home"
# E06 notification shade / E07 quick settings
sh_ cmd statusbar expand-notifications >/dev/null; sleep 1; check_after "E06-shade"; sh_ cmd statusbar collapse >/dev/null
sh_ cmd statusbar expand-settings >/dev/null; sleep 1; check_after "E07-quick-settings"; sh_ cmd statusbar collapse >/dev/null
# E08 volume keys (ring: the alarm stream must not drop)
if [ "$GATE" = ring ]; then
  v0=$(alarm_volume)
  for _ in 1 2 3 4 5; do key KEYCODE_VOLUME_DOWN; done; key KEYCODE_VOLUME_MUTE
  v1=$(alarm_volume)
  if [ "$v0" = "$v1" ] && alarm_playing; then record "E08-volume" 0 "alarm $v1, sounding"; else record "E08-volume" 1 "alarm before [$v0] after [$v1]; sounding=$(alarm_playing && echo yes || echo NO)"; fi
fi
# E11 assistant (long-press Home / KEYCODE_ASSIST) and camera key
key KEYCODE_ASSIST; sleep 1; key KEYCODE_HOME; check_after "E11-assistant"
# E12 / E13 on the PIN gate the screen opens (ring: "Stop ringing"). Inputs that must be refused; never a real PIN.
if [ "$GATE" = ring ] || [ "$GATE" = pin ]; then
  for input in "" "1" "12345678901234567890"; do
    label="E12-pin-$( [ -z "$input" ] && echo empty || echo "len${#input}")"
    if [ "$GATE" = ring ]; then tap_text "Stop ringing" || { record "$label" 1 "no Stop ringing button found"; continue; }; sleep 1; fi
    tap_text "Parent PIN" >/dev/null 2>&1
    [ -n "$input" ] && sh_ input text "$input" >/dev/null
    tap_text "Continue" || { record "$label" 1 "no Continue button on the PIN gate (top=$(top_activity))"; continue; }
    sleep 1
    # Leave the PIN gate the way a child would, then the original gate must be back and intact.
    tap_text "Go back" >/dev/null 2>&1 || key KEYCODE_BACK
    check_after "$label"
  done
fi
# E09 power key: screen off, on (opt-in: needs the owner's unlock on a secure phone)
if [ "$WITH_POWER" = 1 ]; then
  key KEYCODE_POWER; sleep 2
  [ "$GATE" = ring ] && { alarm_playing && record "E09-screen-off-ring" 0 "sounding with screen off" || record "E09-screen-off-ring" 1 "ALARM SILENT with screen off"; }
  key KEYCODE_WAKEUP; check_after "E09-power-on"
fi

# E18: a crash anywhere in the run fails it, even if every row looked fine
CRASH=$("${A[@]}" logcat -d -b crash -T "${T0_DEV}.000" 2>/dev/null | tr -d '\r' | grep -E "Process: $PKG" | head -3)
if [ -n "$CRASH" ]; then record "crash-buffer" 1 "agent crashed during the run: $CRASH (full log in $OUT/crash.txt)"; "${A[@]}" logcat -d -b crash -T "${T0_DEV}.000" > "$OUT/crash.txt" 2>/dev/null
else record "crash-buffer" 0 "no crash of $PKG in logcat -b crash"; fi

# ---------------------------------------------------------------------------------------------------- end
if [ -n "$CLEAR" ]; then echo "clear: $CLEAR"; bash -c "$CLEAR"; fi
sh_ rm -f /sdcard/osra-escape.xml >/dev/null
echo
echo "escape probe ($GATE): $(grep -c $'\tPASS\t' "$RESULTS") pass, $FAILS fail. Results: $RESULTS"
echo "Clear the gate before releasing the lease (AGENTS.md section 9.3): stop_ring / unlock / unblock."
[ "$FAILS" -eq 0 ]
