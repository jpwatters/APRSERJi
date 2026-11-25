#!/bin/zsh
# Commit any changes and push the current branch (and release tags) to github.com/jpwatters/APRSERJi.
# Usage: ./push.sh "What changed"
set -euo pipefail
cd ~/src/APRSERJi
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
