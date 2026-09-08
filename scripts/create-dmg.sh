#!/bin/bash
set +x
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"

usage() {
  printf 'Usage: %s [app-path [output.dmg]]\n' "$0"
  printf 'Defaults: dist/Poem Desktop.app and dist/PoemDesktop.dmg\n'
}

fail() { printf 'DMG packaging failed: %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then usage; exit 0; fi
[[ $# -le 2 ]] || { usage >&2; exit 2; }
[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail 'Run this script on macOS.'

APP_SOURCE="${1:-$PROJECT_DIR/dist/Poem Desktop.app}"
DMG_OUTPUT="${2:-$PROJECT_DIR/dist/PoemDesktop.dmg}"
[[ -d "$APP_SOURCE" && ! -L "$APP_SOURCE" ]] || fail 'The input must be an app bundle, not a symlink.'
[[ -f "$APP_SOURCE/Contents/Info.plist" && -x "$APP_SOURCE/Contents/MacOS/PoemDesktop" ]] || fail 'Poem Desktop.app is incomplete.'
[[ "$DMG_OUTPUT" == *.dmg && ! -L "$DMG_OUTPUT" && ! -d "$DMG_OUTPUT" ]] || fail 'The output must be a .dmg file, not a directory or symlink.'
/usr/bin/codesign --verify --deep --strict "$APP_SOURCE"

mkdir -p "$(dirname "$DMG_OUTPUT")"
DMG_OUTPUT_DIR="$(cd "$(dirname "$DMG_OUTPUT")" && pwd -P)"
DMG_OUTPUT="$DMG_OUTPUT_DIR/$(basename "$DMG_OUTPUT")"
DMG_WORK="$(/usr/bin/mktemp -d "$DMG_OUTPUT_DIR/.poemdesktop-dmg.XXXXXX")"
readonly DMG_WORK
DMG_MOUNT="$DMG_WORK/mounted"
MOUNT_ATTEMPTED=0

cleanup() {
  # Only detach our own private mountpoint. Keep it intact if detaching fails.
  if [[ "$MOUNT_ATTEMPTED" == 1 ]]; then
    if ! /usr/bin/hdiutil detach "$DMG_MOUNT" -quiet >/dev/null 2>&1; then
      printf 'Could not detach the temporary image at %s; its working directory was retained.\n' "$DMG_MOUNT" >&2
      return
    fi
  fi
  /bin/rm -rf "$DMG_WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$DMG_WORK/stage" "$DMG_MOUNT"
/usr/bin/ditto "$APP_SOURCE" "$DMG_WORK/stage/Poem Desktop.app"
/bin/ln -s /Applications "$DMG_WORK/stage/Applications"

# A plain, compressed image needs no Finder automation, layout dependencies,
# background art, or extra files alongside the app and Applications shortcut.
/usr/bin/hdiutil create -quiet -volname 'Poem Desktop' -fs HFS+ -format UDZO \
  -srcfolder "$DMG_WORK/stage" "$DMG_WORK/PoemDesktop.dmg"
/usr/bin/hdiutil verify -quiet "$DMG_WORK/PoemDesktop.dmg"
MOUNT_ATTEMPTED=1
/usr/bin/hdiutil attach -quiet -readonly -nobrowse -noautoopen \
  -mountpoint "$DMG_MOUNT" "$DMG_WORK/PoemDesktop.dmg"
[[ -d "$DMG_MOUNT/Poem Desktop.app" ]] || fail 'The mounted image is missing the app.'
[[ -L "$DMG_MOUNT/Applications" && "$(/usr/bin/readlink "$DMG_MOUNT/Applications")" == /Applications ]] || fail 'The Applications shortcut is invalid.'
/usr/bin/codesign --verify --deep --strict "$DMG_MOUNT/Poem Desktop.app"
/usr/bin/cmp "$APP_SOURCE/Contents/MacOS/PoemDesktop" "$DMG_MOUNT/Poem Desktop.app/Contents/MacOS/PoemDesktop"
/usr/bin/hdiutil detach "$DMG_MOUNT" -quiet
MOUNT_ATTEMPTED=0
/bin/mv -f "$DMG_WORK/PoemDesktop.dmg" "$DMG_OUTPUT"
printf 'Created %s\n' "$DMG_OUTPUT"
