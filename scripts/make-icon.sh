#!/bin/bash
set -euo pipefail

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

if [ "$#" -ne 1 ]; then
  printf 'Usage: %s /path/to/square-icon.png\n' "$0" >&2
  exit 2
fi

[ -f "$1" ] && [ -r "$1" ] || fail "Source must be a readable image file: $1"
SOURCE_DIR="$(cd "$(dirname "$1")" && pwd)"
SOURCE_PATH="$SOURCE_DIR/$(basename "$1")"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

METADATA="$(/usr/bin/sips -g format -g pixelWidth -g pixelHeight "$SOURCE_PATH")" \
  || fail "Unable to read the image: $SOURCE_PATH"
FORMAT="$(printf '%s\n' "$METADATA" | /usr/bin/awk '$1 == "format:" { print $2 }')"
WIDTH="$(printf '%s\n' "$METADATA" | /usr/bin/awk '$1 == "pixelWidth:" { print $2 }')"
HEIGHT="$(printf '%s\n' "$METADATA" | /usr/bin/awk '$1 == "pixelHeight:" { print $2 }')"

[ "$FORMAT" = png ] || fail "Source must be a PNG image."
case "$WIDTH" in
  ''|*[!0-9]*) fail "Unable to determine a valid image width." ;;
esac
case "$HEIGHT" in
  ''|*[!0-9]*) fail "Unable to determine a valid image height." ;;
esac
[ "$WIDTH" -gt 0 ] && [ "$HEIGHT" -gt 0 ] || fail "Image dimensions must be positive."
[ "$WIDTH" -eq "$HEIGHT" ] || fail "Source must be square; received ${WIDTH}×${HEIGHT}."

TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/poem-desktop-icon.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

ICONSET_PATH="$TEMP_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_PATH"
for SIZE in 16 32 128 256 512; do
  /usr/bin/sips -s format png -z "$SIZE" "$SIZE" "$SOURCE_PATH" \
    --out "$ICONSET_PATH/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE_SIZE=$((SIZE * 2))
  /usr/bin/sips -s format png -z "$DOUBLE_SIZE" "$DOUBLE_SIZE" "$SOURCE_PATH" \
    --out "$ICONSET_PATH/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done

/usr/bin/iconutil --convert icns --output "$TEMP_DIR/AppIcon.icns" "$ICONSET_PATH"
mkdir -p "$PROJECT_DIR/Resources"
mv -f "$TEMP_DIR/AppIcon.icns" "$PROJECT_DIR/Resources/AppIcon.icns"
printf 'Created %s\n' "$PROJECT_DIR/Resources/AppIcon.icns"
