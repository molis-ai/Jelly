#!/bin/zsh
set -euo pipefail

(( $# == 0 )) || {
  echo "Usage: $0" >&2
  exit 2
}
[[ "$HOME" == /* && "$HOME" != "/" && -d "$HOME" && ! -L "$HOME" ]] || {
  echo "HOME must be a safe absolute directory." >&2
  exit 2
}

HOME_REAL=$(cd "$HOME" && pwd -P)
[[ "$HOME_REAL" != "/" ]] || {
  echo "HOME must not resolve to the filesystem root." >&2
  exit 2
}
SUPPORT_ROOT="$HOME_REAL/Library/Application Support"
[[ -d "$SUPPORT_ROOT" && ! -L "$SUPPORT_ROOT" ]] || {
  echo "Application Support directory is missing or unsafe: $SUPPORT_ROOT" >&2
  exit 2
}
SUPPORT_REAL=$(cd "$SUPPORT_ROOT" && pwd -P)
FORMAL_DATA="$SUPPORT_REAL/PersonalCalendar"
PREVIEW_DATA="$SUPPORT_REAL/PersonalCalendarPreview"
BACKUP_ROOT="$SUPPORT_REAL/PersonalCalendarPreview-backups"

[[ -d "$FORMAL_DATA" && ! -L "$FORMAL_DATA" ]] || {
  echo "Formal Jelly data directory is missing or unsafe: $FORMAL_DATA" >&2
  exit 2
}
if [[ -L "$PREVIEW_DATA" || ( -e "$PREVIEW_DATA" && ! -d "$PREVIEW_DATA" ) ]]; then
  echo "Preview data target is unsafe: $PREVIEW_DATA" >&2
  exit 2
fi
if [[ -L "$BACKUP_ROOT" || ( -e "$BACKUP_ROOT" && ! -d "$BACKUP_ROOT" ) ]]; then
  echo "Preview backup root is unsafe: $BACKUP_ROOT" >&2
  exit 2
fi
if pgrep -x PersonalCalendar >/dev/null 2>&1; then
  echo "Quit Jelly and Jelly Preview before refreshing Preview data." >&2
  exit 2
fi

tree_digest() {
  local directory="$1"
  (cd "$directory" && /usr/bin/tar -cf - .) | shasum -a 256 | awk '{print $1}'
}

remove_explicit_tree() {
  local target="$1"
  [[ -d "$target" && ! -L "$target" ]] || return 1
  find "$target" -depth -delete
}

STAGING_ROOT=$(mktemp -d "$SUPPORT_REAL/.jelly-preview-refresh.XXXXXX")
STAGING_DATA="$STAGING_ROOT/data"
MOVED_BACKUP=""
PUBLICATION_PENDING=false
HAD_PREVIEW_DATA=false

cleanup() {
  local result=$?
  trap - EXIT HUP INT TERM
  if [[ "$PUBLICATION_PENDING" == true ]]; then
    if [[ "$HAD_PREVIEW_DATA" == true ]]; then
      if [[ -n "$MOVED_BACKUP" && -d "$MOVED_BACKUP" && ! -L "$MOVED_BACKUP" ]]; then
        if [[ -d "$PREVIEW_DATA" && ! -L "$PREVIEW_DATA" ]]; then
          remove_explicit_tree "$PREVIEW_DATA" || true
        fi
        if [[ ! -e "$PREVIEW_DATA" && ! -L "$PREVIEW_DATA" ]]; then
          mv "$MOVED_BACKUP" "$PREVIEW_DATA" || true
        fi
      fi
    elif [[ -d "$PREVIEW_DATA" && ! -L "$PREVIEW_DATA" ]]; then
      remove_explicit_tree "$PREVIEW_DATA" || true
    fi
  fi
  if [[ -d "$STAGING_ROOT" && ! -L "$STAGING_ROOT" ]]; then
    remove_explicit_tree "$STAGING_ROOT" || true
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

FORMAL_BEFORE=$(tree_digest "$FORMAL_DATA")
ditto --norsrc "$FORMAL_DATA" "$STAGING_DATA"
[[ "$FORMAL_BEFORE" == "$(tree_digest "$FORMAL_DATA")" ]] || {
  echo "Formal Jelly data changed during the copy; Preview was left untouched." >&2
  exit 1
}
diff -qr "$FORMAL_DATA" "$STAGING_DATA" >/dev/null || {
  echo "Preview staging verification failed; Preview was left untouched." >&2
  exit 1
}

if [[ -d "$PREVIEW_DATA" ]]; then
  HAD_PREVIEW_DATA=true
  mkdir -p "$BACKUP_ROOT"
  [[ -d "$BACKUP_ROOT" && ! -L "$BACKUP_ROOT" ]] || {
    echo "Could not create a safe Preview backup root." >&2
    exit 2
  }
  [[ "$(stat -f %d "$PREVIEW_DATA")" == "$(stat -f %d "$BACKUP_ROOT")" ]] || {
    echo "Preview data and its rollback backup must be on the same filesystem." >&2
    exit 2
  }
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  MOVED_BACKUP="$BACKUP_ROOT/PersonalCalendarPreview-before-refresh-$timestamp-$$"
  [[ ! -e "$MOVED_BACKUP" && ! -L "$MOVED_BACKUP" ]] || {
    echo "Preview backup target already exists." >&2
    exit 2
  }
fi

PUBLICATION_PENDING=true
if [[ "$HAD_PREVIEW_DATA" == true ]]; then
  mv "$PREVIEW_DATA" "$MOVED_BACKUP"
fi
mv "$STAGING_DATA" "$PREVIEW_DATA"
diff -qr "$FORMAL_DATA" "$PREVIEW_DATA" >/dev/null
[[ "$(tree_digest "$FORMAL_DATA")" == "$FORMAL_BEFORE" ]]
PUBLICATION_PENDING=false

echo "Preview data refreshed: $PREVIEW_DATA"
if [[ -n "$MOVED_BACKUP" ]]; then
  echo "Previous Preview backup: $MOVED_BACKUP"
fi
