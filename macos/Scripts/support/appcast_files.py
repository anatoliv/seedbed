#!/usr/bin/env python3
"""Every file the appcast tells installed copies to download.

    appcast_files.py <appcast.xml> <download-url-prefix> <dist-dir>

Prints the basename of each <enclosure url="..."> in the feed, full DMGs and
Sparkle deltas alike, one per line, and exits 1 if any of them is not a plain
file in <dist-dir> or does not live under <download-url-prefix>.

publish.sh uploads exactly this list. It used to upload the new DMG and the feed
and nothing else, while generate_appcast writes a delta for every older DMG
left in dist/ and advertises each one. So from 0.1.17 on, the served feed named
delta files that had never been uploaded, and every one of them was a 404. Read
from the feed itself, the upload list cannot drift from what the feed promises.
"""

from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def enclosure_urls(appcast: Path) -> list[str]:
    urls = []
    for element in ET.parse(appcast).iter():
        if element.tag.rsplit("}", 1)[-1] == "enclosure":
            url = element.get("url")
            if url:
                urls.append(url)
    return urls


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print("error: usage: appcast_files.py <appcast.xml> <download-url-prefix> <dist-dir>",
              file=sys.stderr)
        return 64
    appcast, prefix, dist = Path(argv[1]), argv[2].rstrip("/") + "/", Path(argv[3])
    try:
        urls = enclosure_urls(appcast)
    except (OSError, ET.ParseError) as error:
        print(f"error: cannot read {appcast}: {error}", file=sys.stderr)
        return 1
    if not urls:
        print(f"error: {appcast} names no downloads.", file=sys.stderr)
        return 1
    problems, names = [], []
    for url in urls:
        name = url[len(prefix):] if url.startswith(prefix) else ""
        if not name or "/" in name or name in (".", ".."):
            problems.append(f"{url} is not a file directly under {prefix}")
        elif not (dist / name).is_file():
            problems.append(f"{url} is advertised, but {dist / name} does not exist")
        elif name not in names:
            names.append(name)
    if problems:
        print("error: the appcast names downloads this publish cannot serve:", file=sys.stderr)
        for problem in problems:
            print(f"       {problem}", file=sys.stderr)
        return 1
    print("\n".join(names))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
