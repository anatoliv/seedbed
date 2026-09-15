#!/usr/bin/env python3
"""Select the prior Seedbed tag, refusing uncertain first-release claims."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


def run(repo: Path, *args: str, allowed: tuple[int, ...] = (0,)) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args], text=True, capture_output=True
    )
    if result.returncode not in allowed:
        raise ValueError(f"git {' '.join(args[:2])} could not be read")
    return result.stdout


def select(
    repo: Path,
    current_version: str,
    first_release: bool,
    cask: Path,
    site: Path,
) -> str:
    if run(repo, "rev-parse", "--is-shallow-repository").strip() != "false":
        raise ValueError("rollback selection requires a complete, non-shallow repository")
    if not run(repo, "remote").split():
        raise ValueError("rollback selection requires a configured remote")
    tag_options = run(
        repo, "config", "--get-regexp", r"^remote\..*\.tagOpt$", allowed=(0, 1)
    )
    if any(line.split()[-1:] == ["--no-tags"] for line in tag_options.splitlines()):
        raise ValueError("a repository configured without tags cannot select a rollback")
    tags = run(repo, "tag", "--list", "v*", "--sort=-v:refname").splitlines()
    cask_text = cask.read_text(encoding="utf-8") if cask.is_file() else ""
    site_text = site.read_text(encoding="utf-8") if site.is_file() else ""
    if first_release:
        if (
            tags
            or re.search(r'^\s*version\s+"[^"]+"', cask_text, re.MULTILINE)
            or re.search(r'Seedbed_[0-9][^"\s]*\.dmg', site_text)
        ):
            raise ValueError("SEEDBED_FIRST_RELEASE=1 contradicts repository release history")
        return ""
    previous = next((tag for tag in tags if tag != f"v{current_version}"), "")
    if not previous:
        raise ValueError("no prior release tag is visible, so rollback history is unknown")
    return previous


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("repo", type=Path)
    parser.add_argument("current_version")
    parser.add_argument("cask", type=Path)
    parser.add_argument("site", type=Path)
    parser.add_argument("--first-release", action="store_true")
    args = parser.parse_args()
    try:
        selected = select(
            args.repo.resolve(), args.current_version, args.first_release, args.cask, args.site
        )
    except (OSError, ValueError) as error:
        print(f"error: {error}.", file=sys.stderr)
        return 1
    print(selected)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
