#!/bin/zsh
# when-idle.sh [--idle seconds] <command...>: runs the command only after the keyboard and mouse have been idle for
# --idle seconds (default 300) and Larynx isn't recording, and kills it the moment any input arrives. Live tests that
# bring a window to the front and paste (tests/live.py) must run through this so they never land in your typing.
set -u
IDLE=300
[[ "${1:-}" == "--idle" ]] && { IDLE=$2; shift 2; }
LARYNX="${LARYNX_BIN:-${0:a:h}/../.build/release/larynx}"
# Seconds since the last keyboard or mouse input from the hardware (so the tests' own synthetic ⌘V doesn't count);
# falls back to IOKit's HIDIdleTime; 0 (never idle) if neither can be read.
idle() {
  local h
  h=$("$LARYNX" idle 2>/dev/null | awk '{print $1}')
  [[ -n "$h" ]] && { echo $h; return; }
  ioidle
}
ioidle() {
  local s
  for _ in 1 2 3; do
    s=$(ioreg -r -k HIDIdleTime -d 1 2>/dev/null | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
    [[ -n "$s" ]] && { echo $s; return; }
    sleep 0.2
  done
  echo 0
}
recording() { tail -1 ~/Library/Logs/Larynx.log 2>/dev/null | grep -qE 'recording\.\.\.|hands-free'; }
# A locked screen won't bring windows to the front, so wait for an unlocked, idle session.
locked() { ioreg -n Root -d1 -a | plutil -extract IOConsoleUsers.0.CGSSessionScreenIsLocked raw -o - - 2>/dev/null | grep -q true; }
until (( $(idle) >= IDLE )) && ! recording && ! locked; do sleep 5; done
export LARYNX_LIVE_OK=1
# While this file exists the command is sending its own keystrokes (a test paste), which reset the idle clocks
# just like a person would; input during those moments is not treated as you. Everything else still is.
export LARYNX_LIVE_MARK="${TMPDIR:-/tmp}/larynx-live-mark-$$"
rm -f "$LARYNX_LIVE_MARK"
"$@" &
pid=$!
start=$(idle)
while kill -0 $pid 2>/dev/null; do
  sleep 0.3
  now=$(idle)
  if [[ -e "$LARYNX_LIVE_MARK" ]]; then start=$now; continue; fi
  if (( now < start )); then   # idle time went back down: someone touched the keyboard or mouse
    pkill -P $pid 2>/dev/null; kill $pid 2>/dev/null
    echo "when-idle: input arrived, stopped the command (idle readings: $("$LARYNX" idle 2>/dev/null), IOKit $(ioidle) s)" >&2
    exit 3
  fi
  start=$now
done
wait $pid
status=$?
rm -f "$LARYNX_LIVE_MARK"
exit $status
