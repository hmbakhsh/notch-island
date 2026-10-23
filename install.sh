#!/bin/bash
# Installs or updates Island: Island.app in ~/Applications, the `notch` CLI in
# ~/.local/bin, and a login item. Re-running it updates from any version.
#   curl -fsSL https://github.com/hmbakhsh/notch-island/releases/latest/download/install.sh | bash
# VERSION=0.1.0 installs that release (rollback). FROM=build/Island.app installs a local build.
# --uninstall removes all three (keeps your history and config).
set -euo pipefail
REPO="hmbakhsh/notch-island"
APP_DIR="${APP_DIR:-$HOME/Applications}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
LABEL="dev.notchisland.island"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$APP_DIR/Island.app"

[[ "$(uname)" == "Darwin" ]] || { echo "Island is Mac-only."; exit 1; }

stop() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  pkill -x Island 2>/dev/null || true
}

if [[ "${1:-}" == "--uninstall" ]]; then
  stop
  rm -rf "$APP" "$AGENT" "$BIN_DIR/notch"
  echo "Uninstalled. History and settings stay in ~/.local/state/notch and ~/.config/notch-island."
  exit 0
fi

# Installed with Homebrew: update through it so brew's record stays right.
for prefix in /opt/homebrew /usr/local; do
  if [[ -z "${FROM:-}" && -d "$prefix/Caskroom/notch-island" ]]; then
    echo "Installed with Homebrew; updating through it."
    "$prefix/bin/brew" update --quiet
    exec "$prefix/bin/brew" upgrade --cask notch-island
  fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if [[ -n "${FROM:-}" ]]; then
  SRC="$FROM"
else
  if [[ -n "${VERSION:-}" ]]; then
    URL="https://github.com/$REPO/releases/download/v${VERSION#v}/Island.zip"
  else
    URL="https://github.com/$REPO/releases/latest/download/Island.zip"
  fi
  echo "Downloading Island…"
  curl -fsSL "$URL" -o "$TMP/Island.zip"
  ditto -x -k "$TMP/Island.zip" "$TMP"
  SRC="$TMP/Island.app"
fi

stop
mkdir -p "$APP_DIR" "$BIN_DIR"
rm -rf "$APP"
ditto "$SRC" "$APP"
ln -sf "$APP/Contents/MacOS/Island" "$BIN_DIR/notch"
# Converge checks and data migrations (also run on every start); writes the login item.
"$APP/Contents/MacOS/Island" --migrate
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "Installed Island $("$APP/Contents/MacOS/Island" --version). Try: notch \"Hello\" -b \"from the notch\" -i hand.wave.fill -c yellow"
