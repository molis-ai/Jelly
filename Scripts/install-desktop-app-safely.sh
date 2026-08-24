#!/bin/zsh
set -euo pipefail

# Installs a reviewed daily Jelly app and snapshots the formal data first.
# Verification launches must still use JELLY_ACCEPTANCE_DATA_DIRECTORY.
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
(( $# <= 1 )) || {
  echo "Usage: $0 [source.app]" >&2
  exit 2
}
SRC="${1:-$ROOT/dist/Jelly.app}"

[[ "$HOME" == /* && "$HOME" != "/" && -d "$HOME" && ! -L "$HOME" ]] || {
  echo "HOME must be a safe absolute directory." >&2
  exit 2
}
HOME_REAL=$(cd "$HOME" && pwd -P)
[[ "$HOME_REAL" != "/" ]] || {
  echo "HOME must not resolve to the filesystem root." >&2
  exit 2
}
DESKTOP_ROOT="$HOME_REAL/Desktop"
SUPPORT_ROOT="$HOME_REAL/Library/Application Support"
[[ -d "$DESKTOP_ROOT" && ! -L "$DESKTOP_ROOT" ]] || {
  echo "Desktop directory is missing or unsafe: $DESKTOP_ROOT" >&2
  exit 2
}
[[ -d "$SUPPORT_ROOT" && ! -L "$SUPPORT_ROOT" ]] || {
  echo "Application Support directory is missing or unsafe: $SUPPORT_ROOT" >&2
  exit 2
}
DESKTOP_REAL=$(cd "$DESKTOP_ROOT" && pwd -P)
SUPPORT_REAL=$(cd "$SUPPORT_ROOT" && pwd -P)
DEST="$DESKTOP_REAL/Jelly.app"
APP_BACKUP_ROOT="$DESKTOP_REAL/Jelly-app-backups"
DATA_DIR="$SUPPORT_REAL/PersonalCalendar"
DATA_BACKUP_ROOT="$SUPPORT_REAL/Jelly-data-backups"

[[ -d "$SRC" && ! -L "$SRC" ]] || { echo "Source app not found or unsafe: $SRC" >&2; exit 2; }
if [[ -L "$DEST" || ( -e "$DEST" && ! -d "$DEST" ) ]]; then
  echo "Destination app target is unsafe: $DEST" >&2
  exit 2
fi
if [[ -L "$DATA_DIR" || ( -e "$DATA_DIR" && ! -d "$DATA_DIR" ) ]]; then
  echo "Formal Jelly data path is unsafe: $DATA_DIR" >&2
  exit 2
fi
for output_root in "$APP_BACKUP_ROOT" "$DATA_BACKUP_ROOT"; do
  if [[ -L "$output_root" || ( -e "$output_root" && ! -d "$output_root" ) ]]; then
    echo "Backup root is unsafe: $output_root" >&2
    exit 2
  fi
done

verify_daily_app() {
  local app="$1"
  local plist="$app/Contents/Info.plist"
  [[ -d "$app" && ! -L "$app" && -f "$plist" && ! -L "$plist" ]] || return 1
  plutil -lint "$plist" >/dev/null || return 1
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == "com.oreal.personalcalendar" ]] || return 1
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :JellyDataProfile' "$plist")" == "daily" ]] || return 1
  local executable
  executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist") || return 1
  [[ -x "$app/Contents/MacOS/$executable" && ! -L "$app/Contents/MacOS/$executable" ]] || return 1
  codesign --verify --deep --strict "$app" || return 1
}

verify_daily_app "$SRC" || {
  echo "Source must be a signed daily Jelly app; Preview builds cannot be promoted directly." >&2
  exit 2
}

paths_overlap() {
  local first="$1"
  local second="$2"
  [[ "$first" == "$second" || "$first" == "$second"/* || "$second" == "$first"/* ]]
}

SRC_REAL=$(cd "$SRC" && pwd -P)
for protected_path in "$DEST" "$APP_BACKUP_ROOT" "$DATA_DIR" "$DATA_BACKUP_ROOT"; do
  paths_overlap "$SRC_REAL" "$protected_path" && {
    echo "Source app must be separate from Jelly install and data directories." >&2
    exit 2
  }
done
if pgrep -x PersonalCalendar >/dev/null 2>&1; then
  echo "Quit Jelly and Jelly Preview before installing a daily build." >&2
  exit 2
fi

STAGE="$DESKTOP_REAL/.Jelly-install-staging-$$.app"
[[ ! -e "$STAGE" && ! -L "$STAGE" ]] || { echo "Install staging target already exists." >&2; exit 2; }
INSTALLED_BACKUP=""
INSTALL_PENDING=false
HAD_DEST_APP=false
DATA_BACKUP_STAGE=""

remove_explicit_tree() {
  local target="$1"
  [[ -d "$target" && ! -L "$target" ]] || return 1
  find "$target" -depth -delete
}

cleanup() {
  local result=$?
  trap - EXIT HUP INT TERM
  if [[ "$INSTALL_PENDING" == true ]]; then
    if [[ "$HAD_DEST_APP" == true ]]; then
      if [[ -n "$INSTALLED_BACKUP" && -d "$INSTALLED_BACKUP" && ! -L "$INSTALLED_BACKUP" ]]; then
        if [[ -d "$DEST" && ! -L "$DEST" ]]; then
          remove_explicit_tree "$DEST" || true
        fi
        if [[ ! -e "$DEST" && ! -L "$DEST" ]]; then
          mv "$INSTALLED_BACKUP" "$DEST" || true
        fi
      fi
    elif [[ -d "$DEST" && ! -L "$DEST" ]]; then
      remove_explicit_tree "$DEST" || true
    fi
  fi
  if [[ -n "$DATA_BACKUP_STAGE" && -d "$DATA_BACKUP_STAGE" && ! -L "$DATA_BACKUP_STAGE" ]]; then
    remove_explicit_tree "$DATA_BACKUP_STAGE" || true
  fi
  if [[ -d "$STAGE" && ! -L "$STAGE" ]]; then
    remove_explicit_tree "$STAGE" || true
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

ditto --norsrc "$SRC_REAL" "$STAGE"
verify_daily_app "$STAGE"
timestamp=$(date -u +%Y%m%dT%H%M%SZ)

mkdir -p "$APP_BACKUP_ROOT"
[[ -d "$APP_BACKUP_ROOT" && ! -L "$APP_BACKUP_ROOT" ]] || {
  echo "App backup root is unsafe." >&2
  exit 2
}
if [[ -d "$DEST" ]]; then
  [[ "$(stat -f %d "$DEST")" == "$(stat -f %d "$APP_BACKUP_ROOT")" ]] || {
    echo "Destination app and its rollback backup must be on the same filesystem." >&2
    exit 2
  }
fi

if [[ -d "$DATA_DIR" ]]; then
  mkdir -p "$DATA_BACKUP_ROOT"
  [[ -d "$DATA_BACKUP_ROOT" && ! -L "$DATA_BACKUP_ROOT" ]] || {
    echo "Formal data backup root is unsafe." >&2
    exit 2
  }
  DATA_BACKUP="$DATA_BACKUP_ROOT/PersonalCalendar-before-install-$timestamp-$$"
  DATA_BACKUP_STAGE="$DATA_BACKUP_ROOT/.PersonalCalendar-before-install-$timestamp-$$.partial"
  [[ ! -e "$DATA_BACKUP" && ! -L "$DATA_BACKUP" && ! -e "$DATA_BACKUP_STAGE" && ! -L "$DATA_BACKUP_STAGE" ]] || {
    echo "Data backup target already exists." >&2
    exit 2
  }
  ditto --norsrc "$DATA_DIR" "$DATA_BACKUP_STAGE"
  diff -qr "$DATA_DIR" "$DATA_BACKUP_STAGE" >/dev/null || {
    echo "Formal data backup verification failed; app was not replaced." >&2
    exit 1
  }
  mv "$DATA_BACKUP_STAGE" "$DATA_BACKUP"
  DATA_BACKUP_STAGE=""
  echo "Formal data backup: $DATA_BACKUP"
fi

if [[ -d "$DEST" ]]; then
  HAD_DEST_APP=true
  INSTALLED_BACKUP="$APP_BACKUP_ROOT/Jelly-$timestamp-$$.app"
  [[ ! -e "$INSTALLED_BACKUP" && ! -L "$INSTALLED_BACKUP" ]] || {
    echo "App backup target already exists." >&2
    exit 2
  }
  echo "Backing up existing Desktop app to $INSTALLED_BACKUP"
fi

INSTALL_PENDING=true
if [[ "$HAD_DEST_APP" == true ]]; then
  mv "$DEST" "$INSTALLED_BACKUP"
fi
mv "$STAGE" "$DEST"
verify_daily_app "$DEST"
INSTALL_PENDING=false

echo "Installed and verified: $DEST"
echo "Verify only with JELLY_ACCEPTANCE_DATA_DIRECTORY set to a temp path."
