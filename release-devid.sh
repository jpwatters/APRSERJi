#!/bin/zsh
# Build, Developer ID-sign, notarize and staple APRSERJi for macOS.
set -euo pipefail
cd ~/src/APRSERJi

TEAM=7Q943H255L
PROFILE=APRSERJi-notary
OUT=build/DeveloperID
ARCHIVE=$OUT/APRSERJi.xcarchive
APP=$OUT/APRSERJi.app
DMG=$OUT/APRSERJi.dmg

# 0. Hardened Runtime blocks Location unless the app is entitled to it (one-time project.yml edit)
if ! grep -q 'personal-information.location' project.yml; then
  perl -0pi -e 's/(path: build\/macOS\.entitlements\n      properties:\n)/$1        com.apple.security.personal-information.location: true\n/' project.yml
  echo "Added the location entitlement to project.yml (commit this change)."
fi

rm -rf "$OUT"; mkdir -p "$OUT"

# 1. Engine + project
./gradlew assembleAprsCoreReleaseXCFramework
xcodegen generate

# 2. Archive with Hardened Runtime (required for notarization)
xcodebuild archive \
  -project APRSERJi.xcodeproj -scheme APRSERJi-macOS -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" -derivedDataPath build/DevIDDD \
  -allowProvisioningUpdates \
  ENABLE_HARDENED_RUNTIME=YES

# 3. Export signed with Developer ID
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportPath "$OUT/export" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -allowProvisioningUpdates
ditto "$OUT/export/APRSERJi-macOS.app" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# 4. Disk image with an Applications shortcut, signed with Developer ID
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep "$TEAM" | head -1 | awk '{print $2}')
[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate found"; exit 1; }
mkdir -p "$OUT/dmg"
ditto "$APP" "$OUT/dmg/APRSERJi.app"
ln -s /Applications "$OUT/dmg/Applications"
# The screenshot tour beside the app (made by ./tour.sh): open "APRSERJi Tour/index.html" in a browser.
if [ -f docs/tour/index.html ]; then
  mkdir -p "$OUT/dmg/APRSERJi Tour"
  rsync -a --exclude '*.png' --exclude '.DS_Store' docs/tour/ "$OUT/dmg/APRSERJi Tour/"
  python3 tour/readme-links.py README.md "$OUT/dmg/APRSERJi Tour/APRSERJi README.md"
fi
# The project document (changes, sources and complete listings) at the top of the disk image.
[ -f docs/APRSERJi.pdf ] && cp docs/APRSERJi.pdf "$OUT/dmg/APRSERJi.pdf"
hdiutil create -volname APRSERJi -srcfolder "$OUT/dmg" -ov -format UDZO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

# 5. Notarize (usually 1–5 minutes), then staple the tickets
RESULT=$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1 | tee /dev/stderr)
if ! print -r -- "$RESULT" | grep -q "status: Accepted"; then
  ID=$(print -r -- "$RESULT" | awk '/^  id:/{print $2; exit}')
  echo "Notarization failed. Details:"; xcrun notarytool log "$ID" --keychain-profile "$PROFILE"
  exit 1
fi
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP"

# 6. Confirm Gatekeeper accepts both
spctl -a -vvv -t install "$DMG"
spctl -a -vvv "$APP"

echo "Done: $DMG"
echo "To install locally:  rm -rf /Applications/APRSERJi.app && ditto \"$APP\" /Applications/APRSERJi.app"
