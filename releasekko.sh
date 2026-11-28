#!/bin/zsh
# Publish a signed, notarized APRSERJi DMG on github.com/kc9kko/APRSERJi-MacOS's Releases page.
# Only the release (DMG and checksum) goes to kc9kko/APRSERJi-MacOS; the source code is not pushed there.
# The version bump is committed and tagged here on this Mac only; ./push.sh sends it to jpwatters/APRSERJi.
# Usage: ./releasekko.sh 0.6.0
set -euo pipefail
VERSION=${1:?usage: ./releasekko.sh <version, e.g. 0.6.0>}
REPO=kc9kko/APRSERJi-MacOS
cd ~/src/APRSERJi
# Use the gh login saved in the keychain; a stale GITHUB_TOKEN in the shell would override it.
unset GITHUB_TOKEN GH_TOKEN

# 0. Checks before anything changes
command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh && gh auth login"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Sign in to GitHub first: gh auth login"; exit 1; }

# Use the KC9KKO GitHub login for this run: switch gh to it (signing it in the first time), then switch
# back to the account that was active before (jpwatters) when the script ends.
PREV_USER=$(gh api user --jq .login)
kko_account() { gh auth status --hostname github.com 2>&1 | grep -o 'account [^ ]*' | awk '{print $2}' | grep -ix kc9kko | head -1; }
if [[ "${PREV_USER:l}" != kc9kko ]]; then
  KKO=$(kko_account || true)
  if [ -z "$KKO" ]; then
    echo "gh isn't signed in as KC9KKO yet. Sign in as KC9KKO in the browser page that opens (this is needed only once)."
    echo "If the browser is signed in to GitHub as jpwatters, copy the link into a private window instead."
    gh auth login --hostname github.com --git-protocol https --web
    KKO=$(kko_account || true)
  fi
  [ -n "$KKO" ] || { echo "gh still isn't signed in as KC9KKO; nothing was changed."; exit 1; }
  gh auth switch --hostname github.com --user "$KKO"
  trap 'gh auth switch --hostname github.com --user "$PREV_USER" >/dev/null 2>&1 || true' EXIT
fi
GH_USER=$(gh api user --jq .login)
[[ "${GH_USER:l}" == kc9kko ]] || { echo "gh is signed in as $GH_USER, not KC9KKO; nothing was changed."; exit 1; }
echo "GitHub login: $GH_USER"
gh repo view "$REPO" >/dev/null 2>&1 || { echo "$GH_USER can't see $REPO. Create it on GitHub first; nothing was changed."; exit 1; }
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then echo "$REPO already has a v$VERSION release"; exit 1; fi
OUT=build/DeveloperID
DMG=APRSERJi-$VERSION.dmg
# A version already released with ./release.sh is published again here from its existing DMG, without rebuilding.
REUSE=0
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  [ -f "$OUT/$DMG" ] || { echo "Tag v$VERSION already exists, but $OUT/$DMG isn't here to publish"; exit 1; }
  REUSE=1
  echo "v$VERSION is already built and tagged; publishing its existing DMG"
fi
echo "Publishing the release to $REPO as $GH_USER"

if [ $REUSE = 0 ]; then
# 1. Make the app report the version from project.yml (one-time edit; it was a fixed 1.0)
if ! grep -q 'CFBundleShortVersionString' project.yml; then
  perl -0pi -e 's/(path: build\/(?:iOS|macOS)-Info\.plist\n      properties:\n)/$1        CFBundleShortVersionString: "\$(MARKETING_VERSION)"\n        CFBundleVersion: "\$(CURRENT_PROJECT_VERSION)"\n/g' project.yml
fi

# 2. Set the version and bump the build number
BUILD=$(( $(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\([0-9]*\)"/\1/p' project.yml) + 1 ))
sed -i '' -e "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" \
          -e "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
echo "Building APRSERJi $VERSION (build $BUILD)"

# 3. Build, Developer ID-sign and notarize (stops here, with nothing published, if it fails)
./release-devid.sh
cp "$OUT/APRSERJi.dmg" "$OUT/$DMG"

# 4. Commit the version and tag it on this Mac only (nothing is pushed)
git add -u && git add release.sh releasekko.sh
git commit -m "Release $VERSION (build $BUILD)"
git tag -a "v$VERSION" -m "APRSERJi $VERSION"
fi
[ -f "$OUT/$DMG.sha256" ] || (cd "$OUT" && shasum -a 256 "$DMG" > "$DMG.sha256")

# 5. Publish the DMG. GitHub needs at least one commit in the repo to hang the release's tag on;
#    if kc9kko/APRSERJi-MacOS is empty, give it a short README first (no source code).
DEFAULT_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name // empty')
if [ -z "$DEFAULT_BRANCH" ]; then
  echo "$REPO is empty; adding a README so the release has something to attach to"
  README=$(printf '# APRSERJi\n\nAPRS station map and two-way messaging for Mac, iPhone and iPad.\n\nDownload the Mac app from [Releases](https://github.com/%s/releases).\n' "$REPO" | base64)
  gh api -X PUT "repos/$REPO/contents/README.md" -f message="Add README" -f content="$README" >/dev/null
  DEFAULT_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name // "main"')
fi
gh release create "v$VERSION" "$OUT/$DMG" "$OUT/$DMG.sha256" \
  --repo "$REPO" \
  --target "$DEFAULT_BRANCH" \
  --title "APRSERJi $VERSION for macOS" \
  --notes "Signed and notarized Mac app (Apple Silicon and Intel, macOS 14 or later). Open the DMG and drag APRSERJi to Applications." \
  --prerelease

echo "Released: https://github.com/$REPO/releases/tag/v$VERSION"
[ $REUSE = 1 ] || echo "The code wasn't pushed anywhere. Run ./push.sh to send the version commit and tag to jpwatters/APRSERJi."
