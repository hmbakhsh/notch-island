#!/bin/bash
# Island items for sketchybar. Source this from your sketchybarrc after your
# other right-side items:
#
#   ISLAND_DIR=/path/to/notch-island/integrations/sketchybar
#   source "$ISLAND_DIR/island.sh"
#
# Adds, right to left: a bell (orange with a count while T3 threads wait on
# you, white when there are unseen messages) and, while Spotify plays, a
# divider, the track title and the artist. Clicking opens the island.

NOTCH="${NOTCH:-$HOME/.local/bin/notch}"
# Icons need a Nerd Font. Override to match your bar, e.g. with
# sketchybar-app-font: SPOTIFY_ICON=":spotify:" SPOTIFY_ICON_FONT="sketchybar-app-font:Regular:16.0"
ICON_FONT="${ISLAND_ICON_FONT:-Hack Nerd Font:Bold:16.0}"
SPOTIFY_ICON="${SPOTIFY_ICON:-󰓇}"
SPOTIFY_ICON_FONT="${SPOTIFY_ICON_FONT:-$ICON_FONT}"
ISLAND_PLUGINS="${ISLAND_DIR:-$(dirname "${BASH_SOURCE[0]}")}/plugins"

# Keep bar items clear of the island's wings (42pt each side of the notch):
# a 185pt notch needs 269pt, plus a little air. Set ISLAND_NOTCH_WIDTH=0 to
# leave your bar's notch_width alone.
NOTCH_WIDTH="${ISLAND_NOTCH_WIDTH:-280}"
(( NOTCH_WIDTH > 0 )) && sketchybar --bar notch_width="$NOTCH_WIDTH"

sketchybar --add event island_update \
           --add item island_bell right \
           --set island_bell icon=󰂚 icon.color=0x66ffffff \
                  icon.font="$ICON_FONT" \
                  label.drawing=off label.color=0xffffa94d label.padding_left=0 \
                  script="$ISLAND_PLUGINS/island_bell.sh" \
                  click_script="$NOTCH --inbox" \
           --subscribe island_bell island_update

# Right items render in reverse insertion order: title, artist, divider, bell.
sketchybar --add event spotify_change com.spotify.client.PlaybackStateChanged \
           --add item spotify_separator right \
           --set spotify_separator drawing=off icon="│" icon.color=0x66ffffff \
                  label.drawing=off padding_left=6 padding_right=6 \
           --add item spotify_artist right \
           --set spotify_artist drawing=off icon.drawing=off \
                  label.color=0xff9ca3af padding_left=0 label.padding_left=6 \
                  click_script="$NOTCH --spotify" \
           --add item spotify right \
           --set spotify drawing=off icon="$SPOTIFY_ICON" icon.font="$SPOTIFY_ICON_FONT" \
                  icon.color=0xff1db954 \
                  icon.padding_right=2 padding_right=0 label.padding_right=4 \
                  script="$ISLAND_PLUGINS/spotify.sh" \
                  click_script="$NOTCH --spotify" \
           --subscribe spotify spotify_change system_woke
