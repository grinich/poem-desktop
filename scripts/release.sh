#!/bin/bash
set +x
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$PROJECT_DIR"
REPOSITORY='grinich/poem-desktop'
DIST_DIR="$PROJECT_DIR/dist"
APP_PATH="$DIST_DIR/Poem Desktop.app"
PUBLISH=0

usage() {
  cat <<'USAGE'
Usage: ./scripts/release.sh [--publish]

Runs tests, builds a universal Developer ID app, notarizes and verifies its
ZIP and DMG, and writes the finished packages and SHA256SUMS under dist/.
--publish additionally creates a new GitHub release for the existing version
tag. Publication requires a clean checkout at the same local and remote tag.

Required: SIGNING_IDENTITY plus either NOTARY_KEYCHAIN_PROFILE or all of
NOTARY_KEY, NOTARY_KEY_ID, and NOTARY_ISSUER. See docs/RELEASING.md.
USAGE
}

fail() { printf 'Release stopped: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  '') [[ $# == 0 ]] || { usage >&2; exit 2; } ;;
  --publish) [[ $# == 1 ]] || { usage >&2; exit 2; }; PUBLISH=1 ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[[ "$(/usr/bin/uname -s)" == Darwin ]] || fail 'Run this script on macOS.'
[[ -n "${SIGNING_IDENTITY:-}" && "$SIGNING_IDENTITY" != '-' ]] || fail 'Set SIGNING_IDENTITY to a Developer ID Application identity in your Keychain.'
export SIGNING_IDENTITY

NOTARY_ARGS=()
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
else
  [[ -n "${NOTARY_KEY:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]] || fail 'Set a Keychain profile or all three App Store Connect team API key variables.'
  [[ -f "$NOTARY_KEY" && -r "$NOTARY_KEY" && ! -L "$NOTARY_KEY" ]] || fail 'NOTARY_KEY must name a readable private key file, not a symlink.'
  NOTARY_KEY_PATH="$(cd "$(dirname "$NOTARY_KEY")" && pwd -P)/$(basename "$NOTARY_KEY")"
  [[ "$NOTARY_KEY_PATH" != "$PROJECT_DIR/"* ]] || fail 'Keep the notarization private key outside this repository.'
  NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
fi
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-2h}"
[[ "$NOTARY_TIMEOUT" =~ ^[1-9][0-9]*[smh]?$ ]] || fail 'NOTARY_TIMEOUT must be a positive duration such as 30m or 2h.'
/usr/bin/xcrun --find notarytool >/dev/null
/usr/bin/xcrun --find stapler >/dev/null
command -v swift >/dev/null || fail 'Install and select Xcode before releasing.'

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'The marketing version must use three numeric components without leading zeros, for example 1.2.0.'
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || fail 'The bundle build number must be a positive integer.'
TAG="v$VERSION"
RELEASE_COMMIT=''

verify_publication_source() {
  command -v gh >/dev/null || fail 'Install GitHub CLI to use --publish.'
  [[ "$(git rev-parse --show-toplevel)" == "$PROJECT_DIR" ]] || fail 'Publish from the Poem Desktop repository root.'
  [[ -z "$(git status --porcelain --untracked-files=all)" ]] || fail 'Commit or remove local changes and untracked files before publishing.'
  local current_commit local_tag remote_refs remote_direct='' remote_peeled='' object_id ref_name release_tags
  current_commit="$(git rev-parse HEAD)"
  local_tag="$(git rev-parse --verify "$TAG^{commit}")" || fail "Create the local $TAG tag before publishing."
  [[ "$local_tag" == "$current_commit" ]] || fail "HEAD must be the commit tagged $TAG."
  [[ -z "$RELEASE_COMMIT" || "$RELEASE_COMMIT" == "$current_commit" ]] || fail 'The checkout changed while preparing this release.'
  remote_refs="$(git ls-remote --exit-code "https://github.com/$REPOSITORY.git" "refs/tags/$TAG" "refs/tags/$TAG^{}")" || fail "Push $TAG to $REPOSITORY before publishing."
  while read -r object_id ref_name; do
    if [[ "$ref_name" == "refs/tags/$TAG^{}" ]]; then remote_peeled="$object_id"; fi
    if [[ "$ref_name" == "refs/tags/$TAG" ]]; then remote_direct="$object_id"; fi
  done <<< "$remote_refs"
  [[ "${remote_peeled:-$remote_direct}" == "$current_commit" ]] || fail 'The GitHub version tag does not match the local release commit.'
  # A successful authenticated listing distinguishes an absent release from a
  # network/authentication failure. gh release create also refuses duplicates.
  release_tags="$(gh api --paginate "repos/$REPOSITORY/releases?per_page=100" --jq '.[].tag_name')" || fail 'Could not verify existing GitHub releases.'
  while IFS= read -r existing_tag; do
    [[ "$existing_tag" != "$TAG" ]] || fail "A release for $TAG already exists; this script never replaces releases or assets."
  done <<< "$release_tags"
  RELEASE_COMMIT="$current_commit"
}

if [[ "$PUBLISH" == 1 ]]; then verify_publication_source; fi

[[ ! -L "$DIST_DIR" && ! -L "$DIST_DIR/notarization" ]] || fail 'Generated release directories must not be symlinks.'
mkdir -p "$DIST_DIR" "$DIST_DIR/notarization" "$PROJECT_DIR/.build/module-cache"
RELEASE_WORK="$(/usr/bin/mktemp -d "$DIST_DIR/.release.XXXXXX")"
readonly RELEASE_WORK
cleanup() { /bin/rm -rf "$RELEASE_WORK"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
LOG_DIR="$(/usr/bin/mktemp -d "$DIST_DIR/notarization/$TAG.XXXXXX")"
readonly LOG_DIR

verify_app() {
  local target="$1" signature="$2"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$target"
  /usr/bin/codesign --display --verbose=4 "$target" 2> "$signature"
  /usr/bin/grep -qx 'Identifier=local.poemdesktop.app' "$signature" || fail 'The app bundle identifier does not match the updater trust requirement.'
  /usr/bin/grep -qx 'TeamIdentifier=VSVHNQP588' "$signature" || fail 'The app signing team does not match the updater trust requirement.'
  /usr/bin/grep -q '^Authority=Developer ID Application:' "$signature" || fail 'The app is not signed with a Developer ID Application certificate.'
  /usr/bin/grep -q '^CodeDirectory.*flags=.*runtime' "$signature" || fail 'The app signature is missing the hardened runtime.'
  /usr/bin/grep -q '^Timestamp=' "$signature" || fail 'The app signature is missing a secure timestamp.'
  /usr/bin/lipo "$target/Contents/MacOS/PoemDesktop" -verify_arch arm64 x86_64
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist")" == local.poemdesktop.app ]] || fail 'The app plist has an unexpected bundle identifier.'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist")" == "$VERSION" ]] || fail 'The built app version does not match Resources/Info.plist.'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$target/Contents/Info.plist")" == "$BUILD_NUMBER" ]] || fail 'The built app build number does not match Resources/Info.plist.'
}

verify_bundle_contents() {
  local entry relative
  # This release has no bundled poem cache, fixtures, credentials, audit images,
  # libraries, or private development files. build.sh assembles this allowlist.
  while IFS= read -r -d '' entry; do
    relative="${entry#"$APP_PATH/"}"
    [[ ! -L "$entry" ]] || fail 'Unexpected symlink in the generated app.'
    case "$relative" in
      Contents/Info.plist|Contents/MacOS/PoemDesktop|Contents/Resources/AppIcon.icns|Contents/_CodeSignature/CodeResources) ;;
      *) fail "Unexpected file in the app bundle: $relative" ;;
    esac
  done < <(/usr/bin/find "$APP_PATH" \( -type f -o -type l \) -print0)
}

notarize() {
  local artifact="$1" label="$2" result="$LOG_DIR/$2-submission.json" status submission_id submit_exit=0
  printf 'Submitting %s for Apple notarization…\n' "$label"
  /usr/bin/xcrun notarytool submit "$artifact" "${NOTARY_ARGS[@]}" \
    --wait --timeout "$NOTARY_TIMEOUT" --output-format json > "$result" || submit_exit=$?
  status="$(/usr/bin/plutil -extract status raw -o - "$result" 2>/dev/null)" || status='Unavailable'
  submission_id="$(/usr/bin/plutil -extract id raw -o - "$result" 2>/dev/null)" || submission_id=''
  if [[ -n "$submission_id" ]]; then
    /usr/bin/xcrun notarytool log "$submission_id" "${NOTARY_ARGS[@]}" "$LOG_DIR/$label-log.json" >/dev/null 2>&1 || true
  fi
  [[ "$submit_exit" == 0 && "$status" == Accepted ]] || fail "$label notarization is $status. Nothing has been published; inspect $result."
  printf '%s notarization accepted.\n' "$label"
}

printf 'Testing Poem Desktop %s (build %s)…\n' "$VERSION" "$BUILD_NUMBER"
CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache" swift test --disable-sandbox
"$PROJECT_DIR/scripts/build.sh"
verify_bundle_contents
verify_app "$APP_PATH" "$LOG_DIR/app-signature.txt"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$RELEASE_WORK/app-for-notarization.zip"
notarize "$RELEASE_WORK/app-for-notarization.zip" app
/usr/bin/xcrun stapler staple "$APP_PATH"
/usr/bin/xcrun stapler validate "$APP_PATH"
verify_app "$APP_PATH" "$LOG_DIR/stapled-app-signature.txt"

# ZIP files cannot carry stapled tickets; rebuild the ZIP from the stapled app.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$RELEASE_WORK/PoemDesktop.app.zip"
"$APP_PATH/Contents/MacOS/PoemDesktop" --validate-update-archive "$RELEASE_WORK/PoemDesktop.app.zip"
mkdir "$RELEASE_WORK/zip-verification"
/usr/bin/ditto -x -k "$RELEASE_WORK/PoemDesktop.app.zip" "$RELEASE_WORK/zip-verification"
verify_app "$RELEASE_WORK/zip-verification/Poem Desktop.app" "$LOG_DIR/zipped-app-signature.txt"
/usr/bin/xcrun stapler validate "$RELEASE_WORK/zip-verification/Poem Desktop.app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$RELEASE_WORK/zip-verification/Poem Desktop.app"

"$PROJECT_DIR/scripts/create-dmg.sh" "$APP_PATH" "$RELEASE_WORK/PoemDesktop.dmg"
/usr/bin/codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$RELEASE_WORK/PoemDesktop.dmg"
/usr/bin/codesign --verify --strict --verbose=2 "$RELEASE_WORK/PoemDesktop.dmg"
notarize "$RELEASE_WORK/PoemDesktop.dmg" dmg
/usr/bin/xcrun stapler staple "$RELEASE_WORK/PoemDesktop.dmg"
/usr/bin/xcrun stapler validate "$RELEASE_WORK/PoemDesktop.dmg"
/usr/bin/codesign --verify --strict --verbose=2 "$RELEASE_WORK/PoemDesktop.dmg"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$RELEASE_WORK/PoemDesktop.dmg"
/usr/bin/hdiutil verify -quiet "$RELEASE_WORK/PoemDesktop.dmg"

(
  cd "$RELEASE_WORK"
  /usr/bin/shasum -a 256 PoemDesktop.app.zip PoemDesktop.dmg > SHA256SUMS
)
RELEASE_NOTES_SOURCE="$PROJECT_DIR/docs/releases/$VERSION.md"
if [[ -f "$RELEASE_NOTES_SOURCE" ]]; then
  [[ ! -L "$RELEASE_NOTES_SOURCE" && -s "$RELEASE_NOTES_SOURCE" ]] || fail 'Version-specific release notes must be a nonempty regular file, not a symlink.'
  /bin/cp "$RELEASE_NOTES_SOURCE" "$RELEASE_WORK/RELEASE_NOTES.md"
else
  cat > "$RELEASE_WORK/RELEASE_NOTES.md" <<NOTES
Poem Desktop $VERSION puts the latest poem from A Poem A Day on your Mac's wallpaper in quiet, black serif type.

- The complete poem stays on one desktop with its original line and stanza breaks.
- Runs without a Dock or menu bar icon, refreshes daily, and can start at login.
- Checks GitHub for app updates daily, verifies the developer signature, and installs and relaunches automatically.
- Includes text-size controls and a larger reading view for unusually long poems.
- Universal app for Apple silicon and Intel Macs running macOS 13 or later.
- Signed with Developer ID, notarized by Apple, and stapled for offline verification.

Download **PoemDesktop.dmg**, open it, and drag **Poem Desktop.app** to **Applications**. Open the app again whenever you want its controls. **PoemDesktop.app.zip** is also available. Verify either download against **SHA256SUMS** if desired.

Version $VERSION · build $BUILD_NUMBER
NOTES
fi

for artifact in PoemDesktop.app.zip PoemDesktop.dmg SHA256SUMS RELEASE_NOTES.md; do
  [[ ! -L "$DIST_DIR/$artifact" && ! -d "$DIST_DIR/$artifact" ]] || fail "Refusing to replace a symlink or directory at dist/$artifact."
done
for artifact in PoemDesktop.app.zip PoemDesktop.dmg SHA256SUMS RELEASE_NOTES.md; do
  /bin/mv -f "$RELEASE_WORK/$artifact" "$DIST_DIR/$artifact"
done
(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 -c SHA256SUMS
)
printf 'Verified packages are ready in dist/. Local notarization logs: %s\n' "$LOG_DIR"

if [[ "$PUBLISH" == 1 ]]; then
  verify_publication_source
  gh release create "$TAG" "$DIST_DIR/PoemDesktop.app.zip" "$DIST_DIR/PoemDesktop.dmg" "$DIST_DIR/SHA256SUMS" \
    --repo "$REPOSITORY" --verify-tag --title "Poem Desktop $VERSION" \
    --notes-file "$DIST_DIR/RELEASE_NOTES.md"
else
  printf 'No GitHub release was created. Use --publish only when the tagged release is ready to make public.\n'
fi
