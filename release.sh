#!/bin/bash
# Publish a new version end to end:  ./release.sh 0.2.0
# Tags it, waits for CI to build and attach the release, then bumps the Homebrew cask if there is one.
set -euo pipefail
V="${1:?usage: ./release.sh <version>   e.g. ./release.sh 0.2.0}"
APP_REPO="hmbakhsh/notch-island"
TAP_REPO="hmbakhsh/homebrew-tap"
CASK="Casks/notch-island.rb"

git tag "v$V"
git push origin "v$V"

echo "Waiting for the release build…"
RUN=""
until [[ -n "$RUN" ]]; do
  sleep 5
  RUN="$(gh run list -R "$APP_REPO" --workflow release.yml --branch "v$V" -L 1 --json databaseId -q '.[0].databaseId')"
done
gh run watch "$RUN" -R "$APP_REPO" --exit-status

if ! FILE="$(gh api "repos/$TAP_REPO/contents/$CASK" 2>/dev/null)"; then
  echo "Released $V. No $CASK in $TAP_REPO yet, so Homebrew was skipped."
  exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
gh release download "v$V" -R "$APP_REPO" -p Island.zip -D "$TMP"
SHA="$(shasum -a 256 "$TMP/Island.zip" | cut -d' ' -f1)"
NEW="$(jq -r .content <<<"$FILE" | base64 -d |
  sed -E "s/^  version \".*\"/  version \"$V\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/")"
gh api -X PUT "repos/$TAP_REPO/contents/$CASK" \
  -f message="notch-island $V" \
  -f content="$(printf '%s\n' "$NEW" | base64)" \
  -f sha="$(jq -r .sha <<<"$FILE")" >/dev/null
echo "Released $V and bumped the cask."
