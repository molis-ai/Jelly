#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd -P)
DIST_DIR="$PROJECT_DIR/dist"
STAGING_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/jelly-preview-build.XXXXXX")
STAGING_APP="$STAGING_ROOT/Jelly Preview.app"
PUBLISHED_APP=""
BACKUP_APP=""
PUBLICATION_PENDING=false
HAD_PUBLISHED_APP=false

remove_generated_app() {
  local target="$1"
  [[ -n "$target" && -d "$target" && ! -L "$target" ]] || return 1
  find "$target" -depth -delete
}

verify_preview_app() {
  local app="$1"
  local plist="$app/Contents/Info.plist"
  [[ -d "$app" && ! -L "$app" && -f "$plist" && ! -L "$plist" ]] || return 1
  plutil -lint "$plist" >/dev/null || return 1
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == "com.oreal.personalcalendar.preview" ]] || return 1
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$plist")" == "Jelly Preview" ]] || return 1
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :JellyDataProfile' "$plist")" == "preview" ]] || return 1
  local executable
  executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist") || return 1
  [[ -x "$app/Contents/MacOS/$executable" && ! -L "$app/Contents/MacOS/$executable" ]] || return 1
  [[ -f "$app/Contents/Resources/AppIconPreview.icns" && ! -L "$app/Contents/Resources/AppIconPreview.icns" ]] || return 1
  codesign --verify --deep --strict "$app" || return 1
}

cleanup() {
  local result=$?
  trap - EXIT HUP INT TERM
  if [[ "$PUBLICATION_PENDING" == true ]]; then
    if [[ "$HAD_PUBLISHED_APP" == true ]]; then
      if [[ -n "$BACKUP_APP" && -d "$BACKUP_APP" && ! -L "$BACKUP_APP" ]]; then
        if [[ -d "$PUBLISHED_APP" && ! -L "$PUBLISHED_APP" ]]; then
          remove_generated_app "$PUBLISHED_APP" || true
        fi
        if [[ ! -e "$PUBLISHED_APP" && ! -L "$PUBLISHED_APP" ]]; then
          mv "$BACKUP_APP" "$PUBLISHED_APP" || true
        fi
      fi
    elif [[ -d "$PUBLISHED_APP" && ! -L "$PUBLISHED_APP" ]]; then
      remove_generated_app "$PUBLISHED_APP" || true
    fi
  fi
  if [[ -d "$STAGING_ROOT" && ! -L "$STAGING_ROOT" ]]; then
    find "$STAGING_ROOT" -depth -delete || true
  fi
  exit "$result"
}

handle_signal() {
  local exit_code="$1"
  trap - HUP INT TERM
  exit "$exit_code"
}

trap cleanup EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

cd "$PROJECT_DIR"
[[ ! -L "$DIST_DIR" ]] || {
  echo "Refusing symlinked dist directory: $DIST_DIR" >&2
  exit 2
}

swift build -c release --product PersonalCalendar
BIN_DIR=$(swift build -c release --show-bin-path)

[[ ! -L "$DIST_DIR" ]] || {
  echo "Refusing symlinked dist directory: $DIST_DIR" >&2
  exit 2
}
mkdir -p "$DIST_DIR"
DIST_REAL=$(cd "$DIST_DIR" && pwd -P)
[[ "$DIST_REAL" == "$PROJECT_DIR/dist" ]] || {
  echo "Unexpected physical dist path: $DIST_REAL" >&2
  exit 2
}

PUBLISHED_APP="$DIST_REAL/Jelly Preview.app"
BACKUP_APP="$DIST_REAL/.Jelly Preview.app.backup.$$"
if [[ -L "$PUBLISHED_APP" || ( -e "$PUBLISHED_APP" && ! -d "$PUBLISHED_APP" ) || -e "$BACKUP_APP" || -L "$BACKUP_APP" ]]; then
  echo "Unexpected Preview app output target." >&2
  exit 2
fi

CONTENTS_DIR="$STAGING_APP/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_DIR/PersonalCalendar" "$MACOS_DIR/PersonalCalendar"
cp "$PROJECT_DIR/Support/Info.plist" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.oreal.personalcalendar.preview' "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Jelly Preview' "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Jelly Preview' "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile AppIconPreview' "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :JellyDataProfile preview' "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Support/AppIconPreview.icns" "$RESOURCES_DIR/AppIconPreview.icns"
chmod +x "$MACOS_DIR/PersonalCalendar"
plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
xattr -cr "$STAGING_APP"
codesign --force --deep --sign - "$STAGING_APP"
xattr -cr "$STAGING_APP"
verify_preview_app "$STAGING_APP"

if [[ -d "$PUBLISHED_APP" ]]; then
  HAD_PUBLISHED_APP=true
fi
PUBLICATION_PENDING=true
if [[ "$HAD_PUBLISHED_APP" == true ]]; then
  mv "$PUBLISHED_APP" "$BACKUP_APP"
fi
mv "$STAGING_APP" "$PUBLISHED_APP"
verify_preview_app "$PUBLISHED_APP"
PUBLICATION_PENDING=false

if [[ -d "$BACKUP_APP" && ! -L "$BACKUP_APP" ]]; then
  remove_generated_app "$BACKUP_APP"
fi
BACKUP_APP=""
echo "$PUBLISHED_APP"
