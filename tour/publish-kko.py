#!/usr/bin/env python3
"""
Publishes README.md and the screenshot tour (docs/tour) to a GitHub repo in one commit, without any source
code: README.md has its other links pointed at jpwatters/APRSERJi, docs/tour goes as it is, and tour files
that no longer exist here are removed there. Files that haven't changed aren't uploaded again.
Used by pushkko.sh. Needs GH_TOKEN (pushkko.sh passes the KC9KKO gh login's token).
Usage: publish-kko.py OWNER/REPO "commit message"
"""
import base64
import hashlib
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = os.path.expanduser("~/src/APRSERJi")
API = "https://api.github.com"
REPO, MESSAGE = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "Update README and tour")
TOKEN = os.environ.get("GH_TOKEN", "")


def call(method, path, body=None, ok_missing=False):
    request = urllib.request.Request(API + path, method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": f"Bearer {TOKEN}", "Accept": "application/vnd.github+json",
                                              "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "APRSERJi-pushkko"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        if ok_missing and error.code in (404, 409):
            return None
        raise SystemExit(f"GitHub {method} {path}: {error.code} {error.read().decode()[:300]}")


def blob_sha(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def local_files():
    files = {}
    readme = subprocess.run([sys.executable, os.path.join(ROOT, "tour/readme-links.py"),
                             os.path.join(ROOT, "README.md"), "/dev/stdout", "--keep-tour"],
                            capture_output=True, check=True).stdout
    files["README.md"] = readme
    tour = os.path.join(ROOT, "docs/tour")
    for folder, _, names in os.walk(tour):
        for name in names:
            if name.startswith(".") or name.endswith(".png"):
                continue
            path = os.path.join(folder, name)
            files[os.path.relpath(path, ROOT)] = open(path, "rb").read()
    return files


def main():
    if not TOKEN:
        raise SystemExit("GH_TOKEN isn't set")
    files = local_files()
    repo = call("GET", f"/repos/{REPO}")
    branch = repo.get("default_branch") or "main"
    ref = call("GET", f"/repos/{REPO}/git/ref/heads/{branch}", ok_missing=True)
    if ref is None:
        # An empty repo has no commit to build on; start it with README.md.
        call("PUT", f"/repos/{REPO}/contents/README.md",
             {"message": "Add README", "content": base64.b64encode(files["README.md"]).decode(), "branch": branch})
        ref = call("GET", f"/repos/{REPO}/git/ref/heads/{branch}")
    head = ref["object"]["sha"]
    base_tree = call("GET", f"/repos/{REPO}/git/commits/{head}")["tree"]["sha"]
    remote = {item["path"]: item["sha"] for item in
              call("GET", f"/repos/{REPO}/git/trees/{base_tree}?recursive=1").get("tree", []) if item["type"] == "blob"}

    changes = []
    for path, data in sorted(files.items()):
        if remote.get(path) == blob_sha(data):
            continue
        sha = call("POST", f"/repos/{REPO}/git/blobs",
                   {"content": base64.b64encode(data).decode(), "encoding": "base64"})["sha"]
        changes.append({"path": path, "mode": "100644", "type": "blob", "sha": sha})
        print(f"  {path}")
    for path in sorted(remote):
        if path.startswith("docs/tour/") and path not in files:
            changes.append({"path": path, "mode": "100644", "type": "blob", "sha": None})
            print(f"  removed {path}")
    if not changes:
        print(f"README.md and the tour on {REPO} are already up to date.")
        return
    tree = call("POST", f"/repos/{REPO}/git/trees", {"base_tree": base_tree, "tree": changes})["sha"]
    commit = call("POST", f"/repos/{REPO}/git/commits", {"message": MESSAGE, "tree": tree, "parents": [head]})["sha"]
    call("PATCH", f"/repos/{REPO}/git/refs/heads/{branch}", {"sha": commit})
    print(f"Pushed {len(changes)} file(s) to {REPO} as {commit[:7]}")


if __name__ == "__main__":
    main()
