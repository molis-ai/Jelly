#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd -P)
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/jelly-preview-refresh-test.XXXXXX")
TEST_HOME="$TEMP_ROOT/home"
SUPPORT="$TEST_HOME/Library/Application Support"
FORMAL="$SUPPORT/PersonalCalendar"
PREVIEW="$SUPPORT/PersonalCalendarPreview"
BACKUPS="$SUPPORT/PersonalCalendarPreview-backups"
FAKE_BIN="$TEMP_ROOT/fake-bin"
BUSY_BIN="$TEMP_ROOT/busy-bin"
SIGNAL_BIN="$TEMP_ROOT/signal-bin"
DEVICE_BIN="$TEMP_ROOT/device-bin"
SIGNAL_MARKER="$TEMP_ROOT/refresh-move-paused"

cleanup() {
  if [[ -d "$TEMP_ROOT" && ! -L "$TEMP_ROOT" ]]; then
    find "$TEMP_ROOT" -depth -delete
  fi
}
trap cleanup EXIT

tree_digest() {
  local directory="$1"
  (cd "$directory" && find -s . -type f -exec shasum -a 256 {} \;) | shasum -a 256 | awk '{print $1}'
}

mkdir -p "$FORMAL/calendar-v1.recovery-snapshots" "$PREVIEW" "$FAKE_BIN" "$BUSY_BIN" "$SIGNAL_BIN" "$DEVICE_BIN"
ln -s /usr/bin/false "$FAKE_BIN/pgrep"
ln -s /usr/bin/true "$BUSY_BIN/pgrep"
ln -s /usr/bin/false "$SIGNAL_BIN/pgrep"
ln -s /usr/bin/false "$DEVICE_BIN/pgrep"
print -r -- '#!/bin/zsh
/bin/mv "$@"
touch "$JELLY_SIGNAL_MARKER"
sleep 1' > "$SIGNAL_BIN/mv"
chmod +x "$SIGNAL_BIN/mv"
print -r -- '#!/bin/zsh
if [[ "$1" == "-f" && "$2" == "%d" ]]; then
  [[ "$3" == "$JELLY_MISMATCH_PATH" ]] && print 2 || print 1
  exit 0
fi
exec /usr/bin/stat "$@"' > "$DEVICE_BIN/stat"
chmod +x "$DEVICE_BIN/stat"
print -n '{"schema":4,"revision":41}' > "$FORMAL/calendar-v1.json"
print -n 'snapshot bytes' > "$FORMAL/calendar-v1.recovery-snapshots/source.bin"
print -n 'old preview data' > "$PREVIEW/old-preview.txt"
FORMAL_BEFORE=$(tree_digest "$FORMAL")
BACKUPS_PHYSICAL="$(cd "$SUPPORT" && pwd -P)/PersonalCalendarPreview-backups"

set +e
HOME="$TEST_HOME" PATH="$FAKE_BIN:$PATH" zsh "$PROJECT_DIR/Scripts/refresh-preview-data.sh" unexpected >/dev/null 2>&1
ARGUMENT_STATUS=$?
set -e
[[ "$ARGUMENT_STATUS" -eq 2 ]]
[[ -f "$PREVIEW/old-preview.txt" ]]

set +e
HOME="$TEST_HOME" PATH="$BUSY_BIN:$PATH" zsh "$PROJECT_DIR/Scripts/refresh-preview-data.sh" >/dev/null 2>&1
RUNNING_APP_STATUS=$?
set -e
[[ "$RUNNING_APP_STATUS" -eq 2 ]]
[[ -f "$PREVIEW/old-preview.txt" ]]
[[ ! -e "$BACKUPS" ]]
[[ "$(tree_digest "$FORMAL")" == "$FORMAL_BEFORE" ]]

set +e
HOME="$TEST_HOME" JELLY_MISMATCH_PATH="$BACKUPS_PHYSICAL" PATH="$DEVICE_BIN:$PATH" \
  zsh "$PROJECT_DIR/Scripts/refresh-preview-data.sh" >/dev/null 2>&1
CROSS_DEVICE_STATUS=$?
set -e
[[ "$CROSS_DEVICE_STATUS" -eq 2 ]]
[[ -f "$PREVIEW/old-preview.txt" ]]
[[ -z "$(find "$BACKUPS" -mindepth 1 -maxdepth 1 -print 2>/dev/null)" ]]
[[ "$(tree_digest "$FORMAL")" == "$FORMAL_BEFORE" ]]
rmdir "$BACKUPS"

HOME="$TEST_HOME" JELLY_SIGNAL_MARKER="$SIGNAL_MARKER" PATH="$SIGNAL_BIN:$PATH" \
  zsh "$PROJECT_DIR/Scripts/refresh-preview-data.sh" >/dev/null 2>&1 &
SIGNAL_PID=$!
for _ in {1..100}; do
  [[ -e "$SIGNAL_MARKER" ]] && break
  sleep 0.02
done
[[ -e "$SIGNAL_MARKER" ]]
kill -TERM "$SIGNAL_PID"
set +e
wait "$SIGNAL_PID"
SIGNAL_STATUS=$?
set -e
[[ "$SIGNAL_STATUS" -eq 143 ]]
[[ "$(<"$PREVIEW/old-preview.txt")" == "old preview data" ]]
[[ "$(tree_digest "$FORMAL")" == "$FORMAL_BEFORE" ]]

OUTPUT=$(HOME="$TEST_HOME" PATH="$FAKE_BIN:$PATH" zsh "$PROJECT_DIR/Scripts/refresh-preview-data.sh")
[[ "$(tree_digest "$FORMAL")" == "$FORMAL_BEFORE" ]]
diff -qr "$FORMAL" "$PREVIEW" >/dev/null
[[ "$OUTPUT" == *"Preview data refreshed"* ]]
BACKUP=$(find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d -print)
[[ -n "$BACKUP" && "$(<"$BACKUP/old-preview.txt")" == "old preview data" ]]

OUTSIDE="$TEMP_ROOT/outside"
mkdir "$OUTSIDE"
print -n 'outside sentinel' > "$OUTSIDE/sentinel"
/bin/mv "$PREVIEW" "$TEMP_ROOT/real-preview"
ln -s "$OUTSIDE" "$PREVIEW"
set +e
HOME="$TEST_HOME" PATH="$FAKE_BIN:$PATH" zsh "$PROJECT_DIR/Scripts/refresh-preview-data.sh" >/dev/null 2>&1
LINK_STATUS=$?
set -e
[[ "$LINK_STATUS" -eq 2 ]]
[[ "$(<"$OUTSIDE/sentinel")" == "outside sentinel" ]]
[[ "$(tree_digest "$FORMAL")" == "$FORMAL_BEFORE" ]]

echo "Preview refresh isolation passed."
