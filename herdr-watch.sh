#!/bin/zsh
# herdr-watch — audible agent status for the OP-XY Claude Deck.
#
# Polls herdr's socket API and chimes when any pane's agent state changes:
#   → blocked   : agent needs you (permission prompt / question)  — urgent sound
#   → done      : agent finished a task                            — soft chime
#   working→idle: turn ended                                       — soft chime
#
# Works for ANY agent herdr detects (Claude Code, Codex, …) — no per-agent hooks.
# Swap the afplay lines for `sendmidi dev "OP-XY" ...` to voice it through the
# OP-XY's own synth instead of the Mac speakers (v0.2 experiment).
#
# Usage: ./herdr-watch.sh [poll-interval-seconds]   (default 2)

INTERVAL=${1:-2}
typeset -A last

sound() {
  afplay "/System/Library/Sounds/$1.aiff" >/dev/null 2>&1 &
}

echo "herdr-watch: polling every ${INTERVAL}s (Ctrl+C to stop)"

while true; do
  herdr pane list 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    for p in d["result"]["panes"]:
        print(p["pane_id"] + "\t" + p["agent_status"])
except Exception:
    pass' | while IFS=$'\t' read -r id st; do
    prev=${last[$id]}
    if [[ -n $prev && $prev != $st ]]; then
      ts=$(date +%H:%M:%S)
      case $st in
        blocked) echo "$ts  $id: $prev → BLOCKED (needs you)"; sound Sosumi ;;
        done)    echo "$ts  $id: $prev → done"; sound Glass ;;
        idle)    if [[ $prev == working ]]; then echo "$ts  $id: working → idle"; sound Glass; fi ;;
        *)       echo "$ts  $id: $prev → $st" ;;
      esac
    fi
    last[$id]=$st
  done
  sleep "$INTERVAL"
done
