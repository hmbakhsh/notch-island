#!/bin/bash

SKETCHYBAR=$(command -v sketchybar || echo /opt/homebrew/bin/sketchybar)

hide() {
  $SKETCHYBAR --set spotify drawing=off --set spotify_artist drawing=off \
    --set spotify_separator drawing=off
  exit 0
}

# Asking Spotify over AppleScript launches it, so check it is running first.
/usr/bin/pgrep -xq Spotify || hide

IFS=$'\t' read -r state track artist < <(/usr/bin/osascript -e '
  tell application "Spotify"
    if player state is stopped then return "stopped"
    return (player state as text) & tab & name of current track & tab & artist of current track
  end tell' 2>/dev/null)

[[ "$state" == "playing" ]] || hide

# Drop "(feat. …)" / "- Remastered" tails, then cap the width.
track="${track%% (*}"
track="${track%% - *}"
artist="${artist%%,*}"
(( ${#track} > 20 )) && track="${track:0:19}…"
(( ${#artist} > 14 )) && artist="${artist:0:13}…"

$SKETCHYBAR --set spotify drawing=on label="$track" \
  --set spotify_artist drawing=on label="$artist" \
  --set spotify_separator drawing=on
