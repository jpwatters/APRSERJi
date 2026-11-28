#!/usr/bin/env python3
"""
Copies README.md with its relative links made absolute, pointing at github.com/jpwatters/APRSERJi (pictures
from raw.githubusercontent.com, other files from github.com), for places where docs/ isn't next to it.
Links into docs/tour/ can be kept relative with --keep-tour (the tour travels with it).
Usage: readme-links.py SOURCE DEST [--keep-tour]
"""
import re
import sys

SOURCE, BRANCH = "jpwatters/APRSERJi", "main"
RAW = f"https://raw.githubusercontent.com/{SOURCE}/{BRANCH}/"
BLOB = f"https://github.com/{SOURCE}/blob/{BRANCH}/"


def rewrite(text, keep_tour):
    relative = r"(?![a-z][a-z0-9+.-]*:|/|#)" + (r"(?!docs/tour/)" if keep_tour else "")
    text = re.sub(r'(src=")' + relative, lambda m: m.group(1) + RAW, text, flags=re.I)
    text = re.sub(r"(!\[[^\]]*\]\()" + relative, lambda m: m.group(1) + RAW, text, flags=re.I)
    text = re.sub(r"((?<!!)\[[^\]]*\]\()" + relative, lambda m: m.group(1) + BLOB, text, flags=re.I)
    text = re.sub(r'(<a href=")' + relative, lambda m: m.group(1) + BLOB, text, flags=re.I)
    return text


if __name__ == "__main__":
    source, dest = sys.argv[1], sys.argv[2]
    keep = "--keep-tour" in sys.argv[3:]
    text = open(source, encoding="utf-8").read()
    open(dest, "w", encoding="utf-8").write(rewrite(text, keep))
