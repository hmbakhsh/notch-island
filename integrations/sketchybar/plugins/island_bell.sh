#!/bin/bash
# Island fires island_update with WAITING and UNREAD. On the first run after a
# reload there is no event, so read the last counts it wrote instead.

STATUS="${ISLAND_STATE_DIR:-$HOME/.local/state/notch}/status.json"
if [[ -z "$WAITING" && -f "$STATUS" ]]; then
  WAITING=$(sed -n 's/.*"waiting": *\([0-9]*\).*/\1/p' "$STATUS")
  UNREAD=$(sed -n 's/.*"unread": *\([0-9]*\).*/\1/p' "$STATUS")
fi
WAITING=${WAITING:-0}
UNREAD=${UNREAD:-0}

if (( WAITING > 0 )); then
  sketchybar --set "$NAME" icon.color=0xffffa94d label="$WAITING" label.drawing=on
elif (( UNREAD > 0 )); then
  sketchybar --set "$NAME" icon.color=0xffffffff label.drawing=off
else
  sketchybar --set "$NAME" icon.color=0x66ffffff label.drawing=off
fi
