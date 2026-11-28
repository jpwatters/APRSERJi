#!/usr/bin/env python3
"""Writes docs/tour/README.md from the screenshots tour.sh took, and the "Application tour" section of README.md."""
import os
import re

ROOT = os.path.expanduser("~/src/APRSERJi")
TOUR = os.path.join(ROOT, "docs/tour")
PLATFORMS = [  # folder, heading, images per row, width in the page
    ("mac", "Mac", 1, 760),
    ("ipad", "iPad", 2, 380),
    ("iphone", "iPhone", 3, 250),
    ("watch", "Apple Watch", 4, 180),
]


def scenes(folder):
    path = os.path.join(TOUR, folder, "scenes.tsv")
    if not os.path.exists(path):
        return []
    rows = []
    for line in open(path, encoding="utf-8"):
        name, _, title = line.rstrip("\n").partition("\t")
        if name and os.path.exists(os.path.join(TOUR, folder, name + ".jpg")):
            rows.append((name, title))
    return rows


def anchor(heading):
    return heading.lower().replace(" ", "-")


def gallery(folder, per_row, width):
    rows = scenes(folder)
    if per_row == 1:
        return "\n".join(f'<p><img src="{folder}/{n}.jpg" width="{width}" alt="{t}"><br><em>{t}</em></p>\n'
                         for n, t in rows)
    out = ["<table>"]
    for i in range(0, len(rows), per_row):
        out.append("<tr>" + "".join(
            f'<td align="center" valign="top" width="{width}"><img src="{folder}/{n}.jpg" width="{width}" '
            f'alt="{t}"><br><sub>{t}</sub></td>' for n, t in rows[i:i + per_row]) + "</tr>")
    out.append("</table>")
    return "\n".join(out)


def main():
    present = [p for p in PLATFORMS if scenes(p[0])]
    if not present:
        print("No screenshots yet; nothing written.")
        return
    parts = ["# APRSERJi application tour", "",
             "Every tab, panel, tool and Setup section, on the Mac, iPad, iPhone and Apple Watch. "
             "The stations and messages are made-up demo data around Goose Lake Prairie State Natural Area, "
             "Grundy County, Illinois. `./tour.sh` makes these screenshots again.", "",
             " · ".join(f"[{h}](#{anchor(h)})" for _, h, _, _ in present), ""]
    for folder, heading, per_row, width in present:
        parts += [f"## {heading}", "", gallery(folder, per_row, width), ""]
    with open(os.path.join(TOUR, "README.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(parts))

    # The same tour as a web page, for the disk image (open index.html in any browser).
    body = [f"<h1>APRSERJi application tour</h1>",
            "<p>Every tab, panel, tool and Setup section, on the Mac, iPad, iPhone and Apple Watch. The stations and "
            "messages are made-up demo data around Goose Lake Prairie State Natural Area, Grundy County, Illinois.</p>",
            "<p>" + " · ".join(f'<a href="#{anchor(h)}">{h}</a>' for _, h, _, _ in present) + "</p>"]
    for folder, heading, per_row, width in present:
        body += [f'<h2 id="{anchor(heading)}">{heading}</h2>', gallery(folder, per_row, width)]
    page = ("<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><title>APRSERJi application tour</title>"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><style>"
            "body{font:15px -apple-system,system-ui,sans-serif;max-width:1100px;margin:2em auto;padding:0 1em;color:#222}"
            "img{max-width:100%;height:auto;border:1px solid #ddd;border-radius:8px}td{padding:8px}"
            "em,sub{color:#555;font-size:13px}h2{margin-top:2em;border-bottom:1px solid #eee}"
            "</style></head><body>\n" + "\n".join(body) + "\n</body></html>\n")
    with open(os.path.join(TOUR, "index.html"), "w", encoding="utf-8") as f:
        f.write(page)

    # README.md: a short section between markers, added at the end the first time.
    thumbs = []
    for folder, heading, _, _ in present:
        names = [n for n, _ in scenes(folder)]
        first = next((n for n in names if "map" in n), names[0])
        width = {"mac": 360, "ipad": 220, "iphone": 130, "watch": 110}[folder]
        thumbs.append(f'<a href="docs/tour/README.md#{anchor(heading)}">'
                      f'<img src="docs/tour/{folder}/{first}.jpg" width="{width}" alt="{heading}"></a>')
    section = ("<!-- tour:start -->\n## Application tour\n\n"
               "A screenshot of every screen on the Mac, iPad, iPhone and Apple Watch, made with demo data by "
               "`./tour.sh`: **[see the full tour](docs/tour/README.md)**.\n\n" + " ".join(thumbs) +
               "\n<!-- tour:end -->")
    readme = os.path.join(ROOT, "README.md")
    text = open(readme, encoding="utf-8").read()
    if "<!-- tour:start -->" in text:
        text = re.sub(r"<!-- tour:start -->.*?<!-- tour:end -->", lambda _: section, text, flags=re.S)
    else:
        text = text.rstrip("\n") + "\n\n" + section + "\n"
    with open(readme, "w", encoding="utf-8") as f:
        f.write(text)
    print("Wrote docs/tour/README.md and the Application tour section of README.md")


if __name__ == "__main__":
    main()
