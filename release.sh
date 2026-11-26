#!/bin/zsh
# Publish a new APRSERJi version: push the code, then post a signed, notarized DMG on GitHub Releases.
# Usage: ./release.sh 0.2.0
set -euo pipefail
VERSION=${1:?usage: ./release.sh <version, e.g. 0.2.0>}
REPO=jpwatters/APRSERJi
cd ~/src/APRSERJi
# Use the gh login saved in the keychain; a stale GITHUB_TOKEN in the shell would override it.
unset GITHUB_TOKEN GH_TOKEN

# 0. Checks before anything changes
command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh && gh auth login"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Sign in to GitHub first: gh auth login"; exit 1; }
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then echo "Tag v$VERSION already exists"; exit 1; fi
BRANCH=$(git branch --show-current)

# 1. Make the app report the version from project.yml (one-time edit; it was a fixed 1.0)
if ! grep -q 'CFBundleShortVersionString' project.yml; then
  perl -0pi -e 's/(path: build\/(?:iOS|macOS)-Info\.plist\n      properties:\n)/$1        CFBundleShortVersionString: "\$(MARKETING_VERSION)"\n        CFBundleVersion: "\$(CURRENT_PROJECT_VERSION)"\n/g' project.yml
fi

# 2. Set the version and bump the build number
BUILD=$(( $(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\([0-9]*\)"/\1/p' project.yml) + 1 ))
sed -i '' -e "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" \
          -e "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
echo "Building APRSERJi $VERSION (build $BUILD)"

# 3. Build, Developer ID-sign and notarize (stops here, with nothing pushed, if it fails)
./release-devid.sh
OUT=build/DeveloperID
DMG=APRSERJi-$VERSION.dmg
cp "$OUT/APRSERJi.dmg" "$OUT/$DMG"
(cd "$OUT" && shasum -a 256 "$DMG" > "$DMG.sha256")

# 4. Commit code changes and the version, push, and bring main up to date
git add -u && git add release.sh
git commit -m "Release $VERSION (build $BUILD)"
git push origin "$BRANCH"
if [ "$BRANCH" != main ]; then
  git checkout main
  git merge --ff-only "$BRANCH"
  git push origin main
  git checkout "$BRANCH"
fi

# 5. Tag the release and publish the DMG
git tag -a "v$VERSION" -m "APRSERJi $VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "$OUT/$DMG" "$OUT/$DMG.sha256" \
  --repo "$REPO" \
  --title "APRSERJi $VERSION for macOS" \
  --notes "Signed and notarized Mac app (Apple Silicon and Intel, macOS 14 or later). Open the DMG and drag APRSERJi to Applications." \
  --prerelease

echo "Released: https://github.com/$REPO/releases/tag/v$VERSION"
