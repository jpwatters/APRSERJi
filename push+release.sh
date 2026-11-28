#!/bin/zsh
# Everything for a new version, in order:
#   1. push.sh       commit all changes and push them to github.com/jpwatters/APRSERJi
#   2. release.sh    set the version, build, sign and notarize the Mac app, tag it and post the DMG on jpwatters/APRSERJi
#   3. pushkko.sh    upload README.md to github.com/kc9kko/APRSERJi-MacOS
#   4. releasekko.sh post the same DMG on kc9kko/APRSERJi-MacOS
#   5. install-iphone.command (optional) install on the iPhone, iPad and Apple Watch
# It stops at the first step that fails.
# Usage: ./push+release.sh 0.5.11 ["What changed"]
#        ./push+release.sh 0.5.11   (proposes a description of the changes, then asks)
#        ./push+release.sh          (proposes the next version and a description of the changes, then asks)
set -euo pipefail
cd ~/src/APRSERJi

# The next version: the newest of the latest release tag and project.yml's version, last number plus one.
propose_version() {
  local tag=$(git tag --list 'v[0-9]*' --sort=-v:refname | head -1)
  local yml=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)
  local latest=$(printf '%s\n%s\n' "${tag#v}" "$yml" | grep -E '^[0-9]' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
  [ -n "$latest" ] || latest=0.0.0
  local parts=(${(s:.:)latest})
  while (( ${#parts} < 3 )); do parts+=0; done
  echo "${parts[1]}.${parts[2]}.$(( parts[3] + 1 ))"
}

# A short description from what changed since the last release tag (committed or not).
propose_message() {
  local tag=$(git tag --list 'v[0-9]*' --sort=-v:refname | head -1)
  local files=$( { [ -n "$tag" ] && git diff --name-only "$tag" HEAD; git status --porcelain | cut -c4-; } | sort -u)
  local -a parts
  print -r -- "$files" | grep -qE '^(Watch/|WatchShared/|App/WatchCompanion)' && parts+="Apple Watch companion app"
  print -r -- "$files" | grep -E '^App/' | grep -qv 'WatchCompanion' && parts+="app updates"
  print -r -- "$files" | grep -qE '^(src/|shared/)' && parts+="APRS core changes"
  print -r -- "$files" | grep -qE '\.(sh|command)$' && parts+="build and publishing scripts"
  print -r -- "$files" | grep -qE '^(README\.md|docs/)' && parts+="README and docs"
  # Commit messages since the last release that say more than "Update APRSERJi".
  local subjects=""
  [ -n "$tag" ] && subjects=$(git log --format=%s "$tag"..HEAD | grep -vE '^(Release |Update APRSERJi$|Changes for |Update README$)' | head -3 | paste -sd ';' - | sed 's/;/; /g' || true)
  local text=${(j:, :)parts}
  [ -n "$subjects" ] && text="${text:+$text; }$subjects"
  [ -n "$text" ] || text="Maintenance release"
  echo "${(U)text[1]}${text[2,-1]}"
}

if (( $# < 2 )); then
  VERSION=${1:-$(propose_version)}
  MESSAGE=$(propose_message)
  print
  print -P "%BProposed release%b"
  echo "  Version:     $VERSION"
  echo "  Description: $MESSAGE"
  echo "  Changes to commit:"
  git status --short | sed 's/^/    /'
  [ -n "$(git status --porcelain)" ] || echo "    (none; already committed)"
  print
  read "answer?Release APRSERJi $VERSION with this description? [y/N] "
  if [[ "$answer" != [yY]* ]]; then
    print
    echo "Not released. To release later, edit this command as you like and run it:"
    echo "  ./push+release.sh $VERSION ${(qq)MESSAGE}"
    exit 0
  fi
else
  VERSION=$1
  MESSAGE=$2
fi

# Checks before anything changes
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || { echo "Version should look like 0.5.11"; exit 1; }
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then echo "Tag v$VERSION already exists; pick a new version"; exit 1; fi
for s in push.sh release.sh pushkko.sh releasekko.sh; do [ -x "$s" ] || { echo "$s is missing or not executable"; exit 1; }; done

step() { print; print -P "%B== $1 ==%b"; }

step "1/5 Commit and push to jpwatters/APRSERJi"
./push.sh "$MESSAGE"
# release.sh commits only files git already tracks, so nothing may be left behind here.
if [ -n "$(git status --porcelain)" ]; then
  echo "Some changes weren't committed (push.sh was answered No?). Stopping before the release."
  git status --short
  exit 1
fi

step "2/5 Release $VERSION on jpwatters/APRSERJi"
./release.sh "$VERSION"

step "3/5 README to kc9kko/APRSERJi-MacOS"
./pushkko.sh "README for $VERSION"

step "4/5 Release $VERSION on kc9kko/APRSERJi-MacOS"
./releasekko.sh "$VERSION"

step "5/5 iPhone, iPad and Apple Watch (optional)"
read "answer?Install $VERSION on your iPhone, iPad and Apple Watch now? [y/N] "
if [[ "$answer" == [yY]* ]]; then
  ./install-iphone.command
else
  echo "Skipped. Run ./install-iphone.command any time."
fi

step "Done: APRSERJi $VERSION"
echo "https://github.com/jpwatters/APRSERJi/releases/tag/v$VERSION"
echo "https://github.com/kc9kko/APRSERJi-MacOS/releases/tag/v$VERSION"
