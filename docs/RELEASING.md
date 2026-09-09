# Releasing Poem Desktop

The release script creates a universal app for Apple silicon and Intel Macs, signs it with Developer ID, notarizes it with Apple, and produces a ZIP and DMG. It runs the unit tests before building. The default command prepares packages; publishing to GitHub requires `--publish`.

## Requirements

- macOS with Xcode selected, including Swift, `notarytool`, and `stapler`.
- An Apple Developer Program membership and a **Developer ID Application** certificate, with its private key, in the signing Mac's unlocked Keychain.
- Notarization credentials in a Keychain profile or an App Store Connect **team** API key. The API key route requires the key file, key ID, and issuer ID.
- GitHub CLI (`gh`) authenticated with release access to `grinich/poem-desktop`, only when using `--publish`.

Packaging uses macOS tools and Xcode; it requires no Homebrew packaging tools or Finder automation. GitHub CLI is only a publishing dependency. Apple notarization requires a network connection. `SIGNING_IDENTITY` must select a Developer ID Application certificate, not an ad hoc or development identity.

The official app and its updater trust bundle identifier `local.poemdesktop.app` and signing team `VSVHNQP588`. The release script enforces both. A fork using a different signing team must deliberately update the updater's trust requirement and the matching release checks before distributing its own app; changing only the certificate would produce updates that existing clients reject.

## Configure credentials

Find the available signing identities:

```sh
security find-identity -v -p codesigning
export SIGNING_IDENTITY='Developer ID Application: YOUR NAME (YOUR_TEAM_ID)'
```

Prefer a Keychain profile. Store credentials once using the interactive prompts, then reference the profile name:

```sh
xcrun notarytool store-credentials 'poem-desktop-notary'
export NOTARY_KEYCHAIN_PROFILE='poem-desktop-notary'
```

Alternatively, use an App Store Connect team API key. Replace the placeholders below with your own values. Keep the private key outside the repository:

```sh
export NOTARY_KEY='/path/outside/the/repository/AuthKey_KEYID.p8'
export NOTARY_KEY_ID='YOUR_KEY_ID'
export NOTARY_ISSUER='YOUR_ISSUER_UUID'
unset NOTARY_KEYCHAIN_PROFILE
```

If a Keychain profile is set, it takes precedence over the API key variables. The script does not store secret values or read a repository `.env` file. Do not commit private keys, certificates, passwords, Keychain exports, or credential configuration. The script disables shell tracing and rejects API key files inside the repository or supplied as symlinks.

The notarization wait timeout defaults to two hours per upload. Set `NOTARY_TIMEOUT=30m`, for example, to change it. A timeout stops packaging without publication; Apple's processing may continue. Submission responses and available logs remain under ignored `dist/notarization/` for investigation. An accepted status is required before stapling or producing publishable assets. See Apple's [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) for retrieving submission status and logs.

## Prepare the version

Update `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`. Use three numeric marketing-version components without leading zeros and an increasing positive build number. For example, **1.2.1** uses build **5**. The script reads both values from the plist and derives the Git tag, such as `v1.2.1`.

Commit the intended source changes. Review the app locally, including a short poem, a long poem, preserved stanza breaks, the controls, and login startup. The archive audit and downloaded poems are local test data and are not release assets.

Write the changes for this version in `docs/releases/VERSION.md`, for example `docs/releases/1.2.2.md`. Packaging copies these committed notes into the GitHub release body. If no version-specific file exists, it generates a general app description.

## Prepare packages

From the repository root, with the credential variables configured:

```sh
./scripts/release.sh
```

This command runs the unit tests, calls `scripts/build.sh`, and verifies both CPU architectures, version/build metadata, Developer ID signing, the hardened runtime, and a secure signing timestamp. It checks that the generated bundle contains only the app executable, plist, icon, and code signature before notarization.

It submits a temporary ZIP to Apple, requires an `Accepted` response, staples and validates the app ticket, then recreates the ZIP from the stapled app. It passes that ZIP through the production updater's archive validator, then extracts it and verifies the shipped app again. ZIP files themselves cannot be stapled; Apple documents this requirement in its [stapling instructions](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

Next it creates a compressed DMG containing **Poem Desktop.app** and an **Applications** shortcut. It mounts the image read-only at a private temporary mountpoint to verify the app and shortcut, then detaches it. The script signs, notarizes, staples, and validates the DMG, runs Gatekeeper assessments on the app and DMG, and verifies the disk image. The DMG assessment follows Apple's [code-signing guidance](https://developer.apple.com/library/archive/technotes/tn2206/).

Only after those checks pass does it write:

| File | Purpose |
| --- | --- |
| `dist/PoemDesktop.app.zip` | Stapled app archive; also used by the app's release update flow |
| `dist/PoemDesktop.dmg` | Signed and stapled drag-to-Applications disk image |
| `dist/SHA256SUMS` | SHA-256 checksums for the ZIP and DMG |
| `dist/RELEASE_NOTES.md` | Generated GitHub release notes |

Generated packages with these names are replaced by later successful packaging runs. Existing GitHub releases and assets are never replaced. `dist/notarization/` contains local diagnostic logs and submission IDs; these are not uploaded as release assets. Logs can include local filesystem paths and must remain private. Downloaded poems, preview images, caches, and archive reports stay in ignored `test-output/`, outside the app bundle and release assets.

For a local packaging preview of an already-built app, run:

```sh
./scripts/create-dmg.sh
```

That helper creates and verifies a plain DMG. It does **not** sign or notarize the disk image; use `release.sh` for distribution. It also accepts an app path and output path as its two positional arguments.

## Publish an explicit release

Publishing requires a clean repository, including no untracked files outside ignored output directories. `HEAD`, the local version tag, and the tag already pushed to `grinich/poem-desktop` must all refer to the same commit. The script checks these conditions before packaging and again before publication. It neither creates nor pushes Git tags.

After committing and reviewing the source:

```sh
git tag -a v1.2.1 -m 'Poem Desktop 1.2.1'
git push origin v1.2.1
./scripts/release.sh --publish
```

Use the matching version tag for later releases. `--publish` reruns the complete build, notarization, and verification process, then invokes `gh release create` with `--verify-tag`. It uploads exactly the ZIP, DMG, and checksum file, using `dist/RELEASE_NOTES.md` as the release body. It fails if the version already has a release, including a draft, and never overwrites assets. If a network failure leaves a partial GitHub release, inspect it before deciding how to recover; the script will not silently replace it on a retry.

The public release page is [github.com/grinich/poem-desktop/releases](https://github.com/grinich/poem-desktop/releases). After publishing, download the DMG through a browser and test installation and opening on a Mac. Check the downloaded checksums with:

```sh
shasum -a 256 -c SHA256SUMS
```

Do not remove quarantine attributes or disable Gatekeeper as part of release validation. A successful public download should open through the normal macOS security flow.
