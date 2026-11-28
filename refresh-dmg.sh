#!/bin/zsh
# Rebuild the disk image of a version that is already released, from its notarized app in build/DeveloperID,
# with the current docs/APRSERJi.pdf and tour; sign, notarize and staple it; and replace it (and its checksum)
# on the jpwatters/APRSERJi and kc9kko/APRSERJi-MacOS releases. The app itself is not rebuilt.
# Usage: ./refresh-dmg.sh 0.5.12
set -euo pipefail
VERSION=${1:?usage: ./refresh-dmg.sh <released version, e.g. 0.5.12>}
cd ~/src/APRSERJi
unset GITHUB_TOKEN GH_TOKEN
TEAM=7Q943H255L
PROFILE=APRSERJi-notary
OUT=build/DeveloperID
APP=$OUT/APRSERJi.app
STAGE=$OUT/dmg-refresh
DMG=$OUT/APRSERJi-$VERSION.dmg

# 0. Checks before anything changes
[ -d "$APP" ] || { echo "$APP isn't here; run ./release.sh for a new version instead"; exit 1; }
APPV=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
[ "$APPV" = "$VERSION" ] || { echo "$APP is version $APPV, not $VERSION"; exit 1; }
xcrun stapler validate "$APP"
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep "$TEAM" | head -1 | awk '{print $2}')
[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate found"; exit 1; }
gh release view "v$VERSION" --repo jpwatters/APRSERJi >/dev/null || { echo "No v$VERSION release on jpwatters/APRSERJi"; exit 1; }

# 1. The disk image: the app, an Applications shortcut, the tour and the project document
rm -rf "${STAGE:?}"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/APRSERJi.app"
ln -s /Applications "$STAGE/Applications"
if [ -f docs/tour/index.html ]; then
  mkdir -p "$STAGE/APRSERJi Tour"
  rsync -a --exclude '*.png' --exclude '.DS_Store' docs/tour/ "$STAGE/APRSERJi Tour/"
  python3 tour/readme-links.py README.md "$STAGE/APRSERJi Tour/APRSERJi README.md"
fi
[ -f docs/APRSERJi.pdf ] && cp docs/APRSERJi.pdf "$STAGE/APRSERJi.pdf"
hdiutil create -volname APRSERJi -srcfolder "$STAGE" -ov -format UDZO "$OUT/APRSERJi.dmg"
codesign --sign "$IDENTITY" --timestamp "$OUT/APRSERJi.dmg"

# 2. Notarize and staple (usually 1–5 minutes)
RESULT=$(xcrun notarytool submit "$OUT/APRSERJi.dmg" --keychain-profile "$PROFILE" --wait 2>&1 | tee /dev/stderr)
if ! print -r -- "$RESULT" | grep -q "status: Accepted"; then
  ID=$(print -r -- "$RESULT" | awk '/^  id:/{print $2; exit}')
  echo "Notarization failed. Details:"; xcrun notarytool log "$ID" --keychain-profile "$PROFILE"
  exit 1
fi
xcrun stapler staple "$OUT/APRSERJi.dmg"
spctl -a -vvv -t install "$OUT/APRSERJi.dmg"
cp "$OUT/APRSERJi.dmg" "$DMG"
(cd "$OUT" && shasum -a 256 "APRSERJi-$VERSION.dmg" > "APRSERJi-$VERSION.dmg.sha256")

# 3. Replace the disk image on both releases
account() { gh auth status --hostname github.com 2>&1 | grep -o 'account [^ ]*' | awk '{print $2}' | grep -ix "$1" | head -1 || true; }
use() { local a=$(account "$1"); [ -n "$a" ] && gh auth switch --hostname github.com --user "$a" >/dev/null; [ -n "$a" ]; }
use jpwatters || { echo "gh isn't signed in as jpwatters"; exit 1; }
gh release upload "v$VERSION" "$DMG" "$DMG.sha256" --repo jpwatters/APRSERJi --clobber
echo "Replaced on https://github.com/jpwatters/APRSERJi/releases/tag/v$VERSION"
if use KC9KKO && gh release view "v$VERSION" --repo kc9kko/APRSERJi-MacOS >/dev/null 2>&1; then
  gh release upload "v$VERSION" "$DMG" "$DMG.sha256" --repo kc9kko/APRSERJi-MacOS --clobber
  echo "Replaced on https://github.com/kc9kko/APRSERJi-MacOS/releases/tag/v$VERSION"
else
  echo "Skipped kc9kko/APRSERJi-MacOS (no KC9KKO login or no v$VERSION release there)"
fi
use jpwatters
