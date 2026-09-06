"""One implementation of "what does the Homebrew cask say", shared by the
release script and the test suite.

The cask's `caveats` block and the DMG's *Before you start.txt* answer the same
question — this app is a front end, here is what it needs before it does
anything — for two audiences who arrive by different routes. Written twice they
drift, and the half nobody installs from is the half that goes stale. So
`macos/Packaging/dmg-readme.txt` is the source and the caveats are generated
from it.

The derivation is deliberately structural rather than a marker comment: markers
in a file a person reads on first launch are clutter, and the readme already has
the shape the split needs.

    Seedbed              <- title
    =======              <- underline
                         <- blank 1
    Drag Seedbed to …    <- the only DMG-specific sentence in the file
                         <- blank 2
    The app is a front …  ┐
    …                     ┘ everything from here is install-method neutral

Everything after the second blank line is the shared body. `assert_shared_body`
refuses a body that has lost either of the two things the cask exists to tell
someone, so restructuring the readme fails loudly here instead of silently
shipping a cask whose caveats are three lines of nothing.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
README = REPO / "macos" / "Packaging" / "dmg-readme.txt"
CASK = REPO / "Casks" / "seedbed.rb"

CAVEATS_INDENT = "    "


def shared_body(readme_text: str) -> str:
    """The install-method-neutral half of the DMG readme."""
    lines = readme_text.splitlines()
    if len(lines) < 3 or not lines[1] or set(lines[1]) != {"="}:
        raise ValueError(
            "dmg-readme.txt no longer opens with a title and an '=' underline; "
            "the caveats derivation reads its structure, so fix one or the other")

    blanks = 0
    for index, line in enumerate(lines):
        if not line.strip():
            blanks += 1
            if blanks == 2:
                return "\n".join(lines[index + 1:]).strip("\n")
    raise ValueError(
        "dmg-readme.txt has fewer than two blank lines; the shared body is "
        "everything after the second one, so there is nothing to generate from")


def assert_shared_body(body: str) -> None:
    """Refuse a body that has stopped saying the two things it exists to say.

    A `brew install` that lands someone in front of "0 prompts · 0 models" with
    no explanation is the failure this whole file is here to prevent, and it is
    exactly what a silently-truncated derivation would produce.
    """
    if "git clone" not in body:
        raise ValueError("the shared body no longer tells anyone to clone the library")
    if "3.11" not in body:
        raise ValueError("the shared body no longer names the Python version it needs")
    for bad, why in (("#{", "Ruby would interpolate it out of the heredoc"),
                     ("\\", "Ruby would read it as an escape")):
        if bad in body:
            raise ValueError(f"the shared body contains {bad!r}: {why}")
    if any(line.strip() == "EOS" for line in body.splitlines()):
        raise ValueError("the shared body contains a bare EOS, which closes the heredoc early")


def caveats_block(body: str) -> str:
    """The `caveats <<~EOS … EOS` lines, indented for the inside of a cask block."""
    out = ["  caveats <<~EOS"]
    for line in body.splitlines():
        out.append(f"{CAVEATS_INDENT}{line}".rstrip())
    out.append("  EOS")
    return "\n".join(out)


def render(cask_text: str, version: str, build: str, sha256: str, body: str) -> str:
    """Return `cask_text` with version, sha256 and caveats set to this release."""
    assert_shared_body(body)

    text, n = re.subn(r'^  version "[^"]*"$', f'  version "{version},{build}"',
                      cask_text, count=1, flags=re.M)
    if n != 1:
        raise ValueError("no `  version \"…\"` line in the cask")

    text, n = re.subn(r'^  sha256 "[^"]*"$', f'  sha256 "{sha256}"',
                      text, count=1, flags=re.M)
    if n != 1:
        raise ValueError("no `  sha256 \"…\"` line in the cask")

    text, n = re.subn(r'^  caveats <<~EOS\n.*?^  EOS$', lambda _: caveats_block(body),
                      text, count=1, flags=re.M | re.S)
    if n != 1:
        raise ValueError("no `  caveats <<~EOS … EOS` block in the cask")
    return text


def main(argv: list[str]) -> int:
    """`cask.py <version> <build> <sha256> [--check]`.

    `--check` reports whether the committed cask already IS what this release
    generates, and writes nothing. It exists because the obvious way to ask that
    question — regenerate, then `git diff` — answers "no change" for a cask that
    is untracked, which is precisely the state it is in before the first commit.
    A check that cannot fail on a brand-new file is not a check.
    """
    args = list(argv[1:])
    check_only = "--check" in args
    if check_only:
        args.remove("--check")
    if len(args) != 3:
        print("usage: cask.py <version> <build> <sha256> [--check]", file=sys.stderr)
        return 2
    version, build, sha256 = args
    if not re.fullmatch(r"[0-9a-f]{64}", sha256):
        print(f"error: {sha256!r} is not a sha256", file=sys.stderr)
        return 1

    body = shared_body(README.read_text())
    current = CASK.read_text()
    updated = render(current, version, build, sha256, body)
    rel = CASK.relative_to(REPO)

    if updated == current:
        print(f"    cask already current: {version},{build}")
        return 0
    if check_only:
        print(f"error: {rel} is not what {README.relative_to(REPO)} and this "
              f"release generate.", file=sys.stderr)
        import difflib
        for line in difflib.unified_diff(
                current.splitlines(), updated.splitlines(),
                fromfile=f"{rel} (committed)", tofile=f"{rel} (generated)", lineterm=""):
            print(f"       {line}", file=sys.stderr)
        print("       Run Scripts/sync-cask.sh. Edit the readme, not the caveats block.",
              file=sys.stderr)
        return 1

    CASK.write_text(updated)
    print(f"    cask synced: {rel} -> {version},{build}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
