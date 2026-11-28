#!/bin/zsh
# Push only README.md to github.com/kc9kko/APRSERJi-MacOS (no code). Its screenshot and document links are
# pointed at jpwatters/APRSERJi, where docs/ lives, so the pictures still show on kc9kko's page.
# Usage: ./pushkko.sh "What changed"
set -euo pipefail
cd ~/src/APRSERJi
MESSAGE=${1:-"Update README"}
REPO=kc9kko/APRSERJi-MacOS
SOURCE=jpwatters/APRSERJi
SOURCE_BRANCH=main
# Use the gh login saved in the keychain; a stale GITHUB_TOKEN in the shell would override it.
unset GITHUB_TOKEN GH_TOKEN

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

# README.md with relative links made absolute: pictures from raw.githubusercontent.com, documents from github.com.
TMP=$(mktemp)
trap 'rm -f "$TMP"; [ "$PREV_USER" != "$GH_USER" ] && gh auth switch --hostname github.com --user "$PREV_USER" >/dev/null 2>&1 || true' EXIT
SOURCE="$SOURCE" SOURCE_BRANCH="$SOURCE_BRANCH" perl -pe '
  my $raw  = "https://raw.githubusercontent.com/$ENV{SOURCE}/$ENV{SOURCE_BRANCH}/";
  my $blob = "https://github.com/$ENV{SOURCE}/blob/$ENV{SOURCE_BRANCH}/";
  s{(src=")(?![a-z][a-z0-9+.-]*:|/|#)}{$1$raw}gi;
  s{(!\[[^\]]*\]\()(?![a-z][a-z0-9+.-]*:|/|#)}{$1$raw}gi;
  s{((?<!!)\[[^\]]*\]\()(?![a-z][a-z0-9+.-]*:|/|#)}{$1$blob}gi;
' README.md > "$TMP"

# Upload it as README.md on kc9kko's default branch, replacing what's there (skipped if nothing changed).
SHA=$(gh api "repos/$REPO/contents/README.md" --jq .sha 2>/dev/null || true)
if [ -n "$SHA" ] && [ "$(gh api "repos/$REPO/contents/README.md" --jq .content | base64 -D)" = "$(cat "$TMP")" ]; then
  echo "README.md on $REPO is already up to date."
  exit 0
fi
ARGS=(-X PUT "repos/$REPO/contents/README.md" -f message="$MESSAGE" -f content="$(base64 < "$TMP")")
[ -n "$SHA" ] && ARGS+=(-f sha="$SHA")
gh api "${ARGS[@]}" --jq '"Pushed README.md as " + .commit.sha[0:7]'
echo "GitHub: https://github.com/$REPO"
