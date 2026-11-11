#!/bin/zsh
# Restarts Larynx.app only when it's idle: not recording and no dictation in the last 30 seconds,
# so an update never cuts someone off mid-sentence. Then waits until the new instance is ready.
LOG=~/Library/Logs/Larynx.log
while true; do
  last=$(tail -1 "$LOG")
  age=$(( $(date +%s) - $(stat -f %m "$LOG") ))
  # "recording..." starts a dictation; "hands-free" means it continues with no key held.
  [[ "$last" != *"recording..."* && "$last" != *"hands-free"* && $age -ge 30 ]] && break
  sleep 3
done
pkill -x larynx; sleep 1
open ~/Applications/Larynx.app
start=$(wc -l < "$LOG")
for i in {1..90}; do
  tail -n +$((start + 1)) "$LOG" | grep -q "ready:" && { echo "Larynx ready"; exit 0; }
  sleep 2
done
echo "Larynx did not report ready within 3 minutes; see $LOG"; exit 1
