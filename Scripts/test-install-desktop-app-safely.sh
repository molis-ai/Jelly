#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd -P)
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/jelly-safe-install-test.XXXXXX")
TEST_HOME="$TEMP_ROOT/home"
SOURCE_APP="$TEMP_ROOT/source/Jelly.app"
DEST_APP="$TEST_HOME/Desktop/Jelly.app"
APP_BACKUPS="$TEST_HOME/Desktop/Jelly-app-backups"
DATA_DIR="$TEST_HOME/Library/Application Support/PersonalCalendar"
DATA_BACKUPS="$TEST_HOME/Library/Application Support/Jelly-data-backups"
FAKE_BIN="$TEMP_ROOT/fake-bin"
BUSY_BIN="$TEMP_ROOT/busy-bin"
PARTIAL_BIN="$TEMP_ROOT/partial-bin"
SIGNAL_BIN="$TEMP_ROOT/signal-bin"
DEVICE_BIN="$TEMP_ROOT/device-bin"
SIGNAL_MARKER="$TEMP_ROOT/install-move-paused"

cleanup() {
  if [[ -d "$TEMP_ROOT" && ! -L "$TEMP_ROOT" ]]; then
    find "$TEMP_ROOT" -depth -delete
  fi
}
trap cleanup EXIT

mkdir -p "$SOURCE_APP/Contents/MacOS" "$DEST_APP/Contents" "$DATA_DIR" \
  "$FAKE_BIN" "$BUSY_BIN" "$PARTIAL_BIN" "$SIGNAL_BIN" "$DEVICE_BIN"
cp "$PROJECT_DIR/Support/Info.plist" "$SOURCE_APP/Contents/Info.plist"
cp /usr/bin/true "$SOURCE_APP/Contents/MacOS/PersonalCalendar"
chmod +x "$SOURCE_APP/Contents/MacOS/PersonalCalendar"
codesign --force --deep --sign - "$SOURCE_APP" >/dev/null
print -n 'old app marker' > "$DEST_APP/Contents/old-app.txt"
print -n '{"schema":4,"revision":57}' > "$DATA_DIR/calendar-v1.json"
ln -s /usr/bin/false "$FAKE_BIN/pgrep"
ln -s /usr/bin/true "$BUSY_BIN/pgrep"
ln -s /usr/bin/false "$PARTIAL_BIN/pgrep"
ln -s /usr/bin/false "$SIGNAL_BIN/pgrep"
ln -s /usr/bin/false "$DEVICE_BIN/pgrep"
print -r -- '#!/bin/zsh
destination="$argv[-1]"
if [[ "$destination" == */.PersonalCalendar-before-install-*.partial ]]; then
  mkdir -p "$destination"
  print -n incomplete > "$destination/incomplete"
  exit 1
fi
exec /usr/bin/ditto "$@"' > "$PARTIAL_BIN/ditto"
chmod +x "$PARTIAL_BIN/ditto"
print -r -- '#!/bin/zsh
/bin/mv "$@"
if [[ "$1" == "$JELLY_SIGNAL_SOURCE" ]]; then
  touch "$JELLY_SIGNAL_MARKER"
  sleep 1
fi' > "$SIGNAL_BIN/mv"
chmod +x "$SIGNAL_BIN/mv"
print -r -- '#!/bin/zsh
if [[ "$1" == "-f" && "$2" == "%d" ]]; then
  [[ "$3" == "$JELLY_MISMATCH_PATH" ]] && print 2 || print 1
  exit 0
fi
exec /usr/bin/stat "$@"' > "$DEVICE_BIN/stat"
chmod +x "$DEVICE_BIN/stat"
DATA_BEFORE=$(shasum -a 256 "$DATA_DIR/calendar-v1.json" | awk '{print $1}')
APP_BACKUPS_PHYSICAL="$(cd "$TEST_HOME/Desktop" && pwd -P)/Jelly-app-backups"

set +e
HOME="$TEST_HOME" PATH="$FAKE_BIN:$PATH" zsh "$PROJECT_DIR/Scripts/install-desktop-app-safely.sh" \
  "$SOURCE_APP" unexpected >/dev/null 2>&1
ARGUMENT_STATUS=$?
set -e
[[ "$ARGUMENT_STATUS" -eq 2 ]]
[[ -f "$DEST_APP/Contents/old-app.txt" ]]

set +e
HOME="$TEST_HOME" PATH="$BUSY_BIN:$PATH" zsh "$PROJECT_DIR/Scripts/install-desktop-app-safely.sh" \
  "$SOURCE_APP" >/dev/null 2>&1
RUNNING_APP_STATUS=$?
set -e
[[ "$RUNNING_APP_STATUS" -eq 2 ]]
[[ -f "$DEST_APP/Contents/old-app.txt" ]]
[[ ! -e "$APP_BACKUPS" && ! -e "$DATA_BACKUPS" ]]
[[ "$(shasum -a 256 "$DATA_DIR/calendar-v1.json" | awk '{print $1}')" == "$DATA_BEFORE" ]]

set +e
HOME="$TEST_HOME" JELLY_MISMATCH_PATH="$APP_BACKUPS_PHYSICAL" PATH="$DEVICE_BIN:$PATH" \
  zsh "$PROJECT_DIR/Scripts/install-desktop-app-safely.sh" "$SOURCE_APP" >/dev/null 2>&1
CROSS_DEVICE_STATUS=$?
set -e
[[ "$CROSS_DEVICE_STATUS" -eq 2 ]]
[[ -f "$DEST_APP/Contents/old-app.txt" ]]
[[ -z "$(find "$APP_BACKUPS" -mindepth 1 -maxdepth 1 -print 2>/dev/null)" ]]
[[ ! -e "$DATA_BACKUPS" ]]

set +e
HOME="$TEST_HOME" PATH="$PARTIAL_BIN:$PATH" zsh "$PROJECT_DIR/Scripts/install-desktop-app-safely.sh" \
  "$SOURCE_APP" >/dev/null 2>&1
PARTIAL_BACKUP_STATUS=$?
set -e
[[ "$PARTIAL_BACKUP_STATUS" -eq 1 ]]
[[ -f "$DEST_APP/Contents/old-app.txt" ]]
[[ -z "$(find "$DATA_BACKUPS" -mindepth 1 -maxdepth 1 -print 2>/dev/null)" ]]
[[ "$(shasum -a 256 "$DATA_DIR/calendar-v1.json" | awk '{print $1}')" == "$DATA_BEFORE" ]]

SIGNAL_SOURCE_PATH=$(cd "$DEST_APP" && pwd -P)
HOME="$TEST_HOME" JELLY_SIGNAL_SOURCE="$SIGNAL_SOURCE_PATH" JELLY_SIGNAL_MARKER="$SIGNAL_MARKER" \
  PATH="$SIGNAL_BIN:$PATH" zsh "$PROJECT_DIR/Scripts/install-desktop-app-safely.sh" "$SOURCE_APP" >/dev/null 2>&1 &
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
[[ "$(<"$DEST_APP/Contents/old-app.txt")" == "old app marker" ]]
[[ "$(shasum -a 256 "$DATA_DIR/calendar-v1.json" | awk '{print $1}')" == "$DATA_BEFORE" ]]

HOME="$TEST_HOME" PATH="$FAKE_BIN:$PATH" zsh "$PROJECT_DIR/Scripts/install-desktop-app-safely.sh" \
  "$SOURCE_APP" >/dev/null

codesign --verify --deep --strict "$DEST_APP"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :JellyDataProfile' "$DEST_APP/Contents/Info.plist")" == "daily" ]]
[[ "$(shasum -a 256 "$DATA_DIR/calendar-v1.json" | awk '{print $1}')" == "$DATA_BEFORE" ]]
APP_BACKUP=$(find "$APP_BACKUPS" -mindepth 1 -maxdepth 1 -type d -print)
[[ -f "$APP_BACKUP/Contents/old-app.txt" ]]
DATA_BACKUP_COUNT=0
for data_backup in "$DATA_BACKUPS"/PersonalCalendar-before-install-*; do
  [[ -d "$data_backup" ]] || continue
  (( DATA_BACKUP_COUNT += 1 ))
  [[ "$(shasum -a 256 "$data_backup/calendar-v1.json" | awk '{print $1}')" == "$DATA_BEFORE" ]]
done
[[ "$DATA_BACKUP_COUNT" -eq 2 ]]

PREVIEW_SOURCE="$TEMP_ROOT/source/Jelly Preview.app"
ditto --norsrc "$SOURCE_APP" "$PREVIEW_SOURCE"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.oreal.personalcalendar.preview' "$PREVIEW_SOURCE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :JellyDataProfile preview' "$PREVIEW_SOURCE/Contents/Info.plist"
codesign --force --deep --sign - "$PREVIEW_SOURCE" >/dev/null
APP_BACKUP_COUNT=$(find "$APP_BACKUPS" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')

set +e
HOME="$TEST_HOME" PATH="$FAKE_BIN:$PATH" zsh "$PROJECT_DIR/Scripts/install-desktop-app-safely.sh" \
  "$PREVIEW_SOURCE" >/dev/null 2>&1
PREVIEW_STATUS=$?
HOME="$TEST_HOME" PATH="$FAKE_BIN:$PATH" zsh "$PROJECT_DIR/Scripts/install-desktop-app-safely.sh" \
  "$DEST_APP" >/dev/null 2>&1
INSTALLED_SOURCE_STATUS=$?
set -e

[[ "$PREVIEW_STATUS" -eq 2 ]]
[[ "$INSTALLED_SOURCE_STATUS" -eq 2 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :JellyDataProfile' "$DEST_APP/Contents/Info.plist")" == "daily" ]]
[[ "$(find "$APP_BACKUPS" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')" == "$APP_BACKUP_COUNT" ]]
[[ "$(shasum -a 256 "$DATA_DIR/calendar-v1.json" | awk '{print $1}')" == "$DATA_BEFORE" ]]

echo "Safe daily install and data backup passed."
