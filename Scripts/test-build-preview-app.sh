#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd -P)
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/jelly-preview-build-test.XXXXXX")

cleanup() {
  if [[ -d "$TEMP_ROOT" && ! -L "$TEMP_ROOT" ]]; then
    find "$TEMP_ROOT" -depth -delete
  fi
}
trap cleanup EXIT

zsh "$PROJECT_DIR/Scripts/build-preview-app.sh" >/dev/null

APP="$PROJECT_DIR/dist/Jelly Preview.app"
PLIST="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/PersonalCalendar"
ICON="$APP/Contents/Resources/AppIconPreview.icns"
OLD_EXECUTABLE_HASH=$(shasum -a 256 "$EXECUTABLE" | awk '{print $1}')

FAKE_BIN="$TEMP_ROOT/fake-bin"
FAKE_SWIFT_BIN="$TEMP_ROOT/swift-bin"
SIGNAL_MARKER="$TEMP_ROOT/build-move-paused"
mkdir -p "$FAKE_BIN" "$FAKE_SWIFT_BIN"
cp /usr/bin/true "$FAKE_SWIFT_BIN/PersonalCalendar"
print -r -- '#!/bin/zsh
if [[ "$*" == *"--show-bin-path"* ]]; then
  print -r -- "$JELLY_FAKE_SWIFT_BIN"
fi' > "$FAKE_BIN/swift"
print -r -- '#!/bin/zsh
/bin/mv "$@"
if [[ "$1" == "$JELLY_SIGNAL_SOURCE" ]]; then
  touch "$JELLY_SIGNAL_MARKER"
  sleep 1
fi' > "$FAKE_BIN/mv"
chmod +x "$FAKE_BIN/swift" "$FAKE_BIN/mv" "$FAKE_SWIFT_BIN/PersonalCalendar"

JELLY_FAKE_SWIFT_BIN="$FAKE_SWIFT_BIN" JELLY_SIGNAL_SOURCE="$APP" JELLY_SIGNAL_MARKER="$SIGNAL_MARKER" \
  PATH="$FAKE_BIN:$PATH" zsh "$PROJECT_DIR/Scripts/build-preview-app.sh" >/dev/null 2>&1 &
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
[[ "$(shasum -a 256 "$EXECUTABLE" | awk '{print $1}')" == "$OLD_EXECUTABLE_HASH" ]]

[[ -d "$APP" && ! -L "$APP" ]]
[[ -f "$PLIST" && ! -L "$PLIST" ]]
[[ -x "$EXECUTABLE" && ! -L "$EXECUTABLE" ]]
[[ -f "$ICON" && ! -L "$ICON" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" == "com.oreal.personalcalendar.preview" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$PLIST")" == "Jelly Preview" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$PLIST")" == "Jelly Preview" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :JellyDataProfile' "$PLIST")" == "preview" ]]
[[ "$(shasum -a 256 "$ICON" | awk '{print $1}')" != "$(shasum -a 256 "$PROJECT_DIR/Support/AppIcon.icns" | awk '{print $1}')" ]]
codesign --verify --deep --strict "$APP"

echo "Jelly Preview build identity passed."
