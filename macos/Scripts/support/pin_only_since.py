#!/usr/bin/env python3
"""Is HEAD the build commit, or the build commit plus only its release pin?

    pin_only_since.py <repo> <build-commit> <head>

Exit 0 when <head> is <build-commit>, or descends from it and the two trees
differ only in the files release.sh repins after the build: the Homebrew cask
and the site's download links. Exit 1 otherwise, naming why.

release.sh builds at one commit and then rewrites the pin, and its own tagging
step says to commit the pin before tagging so the tag contains it. The release
gate compared the bundle's recorded commit with HEAD exactly, so committing the
pin as instructed made publish.sh refuse the release it was about to publish.
The order that worked was publish first and commit after, which nothing said.
This is the narrow way through: the recorded commit is still exact, and the
only thing allowed on top of it is the pin itself.
"""

from __future__ import annotations

import subprocess
import sys

PIN_FILES = frozenset({"Casks/seedbed.rb", "site/index.html"})


def git(repo: str, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", "-C", repo, *args], text=True,
                          capture_output=True, check=False)


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print("error: usage: pin_only_since.py <repo> <build-commit> <head>", file=sys.stderr)
        return 64
    repo, build, head = argv[1:]
    resolved = []
    for name in (build, head):
        result = git(repo, "rev-parse", "--verify", "--quiet", f"{name}^{{commit}}")
        if result.returncode != 0:
            print(f"error: {name} is not a commit in this repository.", file=sys.stderr)
            return 1
        resolved.append(result.stdout.strip())
    build, head = resolved
    if build == head:
        return 0
    if git(repo, "merge-base", "--is-ancestor", build, head).returncode != 0:
        print(f"error: HEAD {head} does not descend from the build commit {build}.",
              file=sys.stderr)
        return 1
    diff = git(repo, "diff", "--name-only", "--no-renames", build, head)
    if diff.returncode != 0:
        print("error: could not compare the build commit with HEAD.", file=sys.stderr)
        return 1
    changed = sorted(set(filter(None, diff.stdout.splitlines())))
    extra = [path for path in changed if path not in PIN_FILES]
    if extra:
        print(f"error: HEAD changes more than the release pin since {build}:", file=sys.stderr)
        for path in extra[:20]:
            print(f"       {path}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
