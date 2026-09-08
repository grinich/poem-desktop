#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/module-cache dist
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"
swift build -c release --disable-sandbox --arch arm64 --arch x86_64
BINARY_DIR="$(swift build -c release --disable-sandbox --arch arm64 --arch x86_64 --show-bin-path)"
APP_PATH="$PROJECT_DIR/dist/Poem Desktop.app"
# Recreate only our generated bundle so removed resources cannot survive a rebuild.
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BINARY_DIR/PoemDesktop" "$APP_PATH/Contents/MacOS/PoemDesktop"
cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_PATH/Contents/Resources/AppIcon.icns"
/usr/bin/xattr -cr "$APP_PATH"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" --identifier local.poemdesktop.app "$APP_PATH"
else
  /usr/bin/codesign --force --sign - --identifier local.poemdesktop.app "$APP_PATH"
fi
/usr/bin/codesign --verify --strict "$APP_PATH"
/usr/bin/lipo "$APP_PATH/Contents/MacOS/PoemDesktop" -verify_arch arm64 x86_64
printf 'Built %s\n' "$APP_PATH"
