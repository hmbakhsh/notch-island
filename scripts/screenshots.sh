#!/bin/bash
# Regenerates docs/screenshots/ from demo data: a throwaway history and a fake
# T3 database, so no real messages or thread titles end up in the images.
# Stops the installed Island while it runs and restarts it afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."

DEMO=$(mktemp -d)
OUT=docs/screenshots
BIN=.build/release/Island
LABEL=dev.notchisland.island
mkdir -p "$OUT"
swift build -c release >/dev/null

restore() {
  pkill -f "$BIN" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist" 2>/dev/null || true
}
trap restore EXIT
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x Island 2>/dev/null || true
sleep 0.5

ago() { date -u -v-"$1" +%Y-%m-%dT%H:%M:%S.000Z; }

sqlite3 "$DEMO/t3.sqlite" <<SQL
create table projection_projects (project_id text, title text);
create table orchestration_v2_projection_threads (
  thread_id text, project_id text, title text, updated_at text,
  archived_at text, deleted_at text, payload_json text);
create table orchestration_v2_projection_runs (
  thread_id text, ordinal int, status text, completed_at text, payload_json text);
create table orchestration_v2_projection_runtime_requests (
  thread_id text, status text, created_at text);
insert into projection_projects values ('p1', 'web-app'), ('p2', 'api');
insert into orchestration_v2_projection_threads values
  ('t1', 'p1', 'Migrate auth to passkeys', '$(ago 3M)', null, null, '{"lastVisitedAt": "$(ago 30M)", "lineage": {}}'),
  ('t2', 'p2', 'Fix flaky checkout e2e test', '$(ago 2M)', null, null, '{"lastVisitedAt": "$(ago 30M)", "lineage": {}}'),
  ('t3', 'p2', 'Bump dependencies', '$(ago 1M)', null, null, '{"lastVisitedAt": "$(ago 30M)", "lineage": {}}');
insert into orchestration_v2_projection_runs values
  ('t1', 1, 'completed', '$(ago 3M)', '{"modelSelection": {"model": "claude-opus-5-5"}, "startedAt": "$(ago 7M)"}'),
  ('t2', 1, 'running', null, '{"modelSelection": {"model": "gpt-6.1-sol"}, "startedAt": "$(ago 5M)"}'),
  ('t3', 1, 'failed', '$(ago 1M)', '{"modelSelection": {"model": "claude-sonnet-5-5"}, "startedAt": "$(ago 2M)"}');
insert into orchestration_v2_projection_runtime_requests values ('t2', 'pending', '$(ago 2M)');
SQL

ISLAND_STATE_DIR="$DEMO/state" ISLAND_T3_DB="$DEMO/t3.sqlite" ISLAND_ANNOUNCE_EXISTING=1 \
  "$BIN" >/dev/null 2>&1 &

# The island's panel, found by owner; captured alone with its transparency.
window() {
  osascript -l JavaScript -e '
    ObjC.import("CoreGraphics");
    const ws = ObjC.deepUnwrap(ObjC.castRefToObject(
      $.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));
    const w = ws.find(w => w.kCGWindowOwnerName === "Island");
    w ? w.kCGWindowNumber : "";'
}
shot() { sleep "$2"; screencapture -x -o -l "$(window)" "$OUT/$1.png"; echo "$OUT/$1.png"; }

# T3 threads are announced oldest first, one every ~8.6s.
shot t3-finished 1.6
shot t3-question 8.6
shot t3-failed 8.6
sleep 8

NOTCH() { "$BIN" notify "$@"; }
NOTCH "Tests passed" -b "412 passed in 2m 14s" -s "Claude · api" -i checkmark.circle.fill -c green -t 4
shot message-success 1.2
sleep 4
NOTCH "Deploy failed" -b "railway: build step exited 1" -s "Codex · web-app" -i xmark.octagon.fill -c red -t 3
NOTCH "PR #482 ready for review" -b "Passkey login, 14 files changed" -s "Claude · web-app" -i arrow.triangle.pull -c purple -t 3
sleep 9

"$BIN" inbox
shot inbox 1.2
"$BIN" inbox
sleep 0.8

if pgrep -xq Spotify; then
  "$BIN" spotify
  shot spotify 1.4
  "$BIN" spotify
fi
