#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
"$PROJECT_DIR/scripts/build.sh"
DESTINATION="$HOME/Applications/Poem Desktop.app"
if [[ -e "$DESTINATION" ]]; then
  IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION/Contents/Info.plist")
  [[ "$IDENTIFIER" == "local.poemdesktop.app" ]] || { printf 'A different app already exists at %s\n' "$DESTINATION"; exit 1; }
  "$DESTINATION/Contents/MacOS/PoemDesktop" --quit-existing
  for ATTEMPT in {1..40}; do
    if ! /usr/bin/pgrep -f "^$DESTINATION/Contents/MacOS/PoemDesktop([[:space:]]|$)" >/dev/null; then break; fi
    /bin/sleep 0.25
  done
  if /usr/bin/pgrep -f "^$DESTINATION/Contents/MacOS/PoemDesktop([[:space:]]|$)" >/dev/null; then
    printf 'Please quit Poem Desktop before reinstalling.\n'
    exit 1
  fi
fi
mkdir -p "$HOME/Applications"
/usr/bin/ditto "$PROJECT_DIR/dist/Poem Desktop.app" "$DESTINATION"
/usr/bin/open -g "$DESTINATION" --args --enable-login
printf 'Installed %s\n' "$DESTINATION"
