#!/bin/zsh
# Commit any changes and push the current branch (and release tags) to github.com/jpwatters/APRSERJi.
# Usage: ./push.sh "What changed"
set -euo pipefail
cd ~/src/APRSERJi
# Use the gh login saved in the keychain; a stale GITHUB_TOKEN in the shell would override it.
unset GITHUB_TOKEN GH_TOKEN
command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh && gh auth login"; exit 1; }
# Use the jpwatters GitHub login for this run (gh may have been left on KC9KKO by another script).
JPW=$(gh auth status --hostname github.com 2>&1 | grep -o 'account [^ ]*' | awk '{print $2}' | grep -ix jpwatters | head -1 || true)
[ -n "$JPW" ] || { echo "gh isn't signed in as jpwatters; run gh auth login and sign in as jpwatters. Nothing was changed."; exit 1; }
[[ "$(gh api user --jq .login 2>/dev/null || true)" == "$JPW" ]] || gh auth switch --hostname github.com --user "$JPW"
echo "GitHub login: $(gh api user --jq .login)"
MESSAGE=${1:-"Update APRSERJi"}
BRANCH=$(git branch --show-current)

# Keep Finder's .DS_Store files out of the repository.
grep -qxF '.DS_Store' .gitignore 2>/dev/null || echo '.DS_Store' >> .gitignore

git add -A
if git diff --cached --quiet; then
  echo "No new changes to commit."
else
  echo "About to commit on $BRANCH:"
  git status --short
  read "answer?Commit and push these? [y/N] "
  [[ "$answer" == [yY]* ]] || { git reset -q; echo "Nothing committed."; exit 0; }
  git commit -m "$MESSAGE"
fi

git push -u origin "$BRANCH"
git push origin --tags
echo
git status -sb | head -1
echo "GitHub: https://github.com/jpwatters/APRSERJi/tree/$BRANCH"
