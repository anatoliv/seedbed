"""The snapshot guards, run against the source instead of only at publish time.

Companion to `test_publish_guards.py`, which pins that the script refuses a
working tree nobody looked at. That one is about WHEN the snapshot is taken;
this one is about WHAT is in it.

`Scripts/publish-repo.sh` refuses to publish a snapshot containing a private
address, a credential, an internal name or a reference to a path its excludes
removed. All of that runs on the mirror, at publish time, and the script is
itself excluded from the snapshot, so the public tree cannot see the rules it is
held to and the source tree is never measured against them until a publish
aborts.

That has now cost two publishes for unrelated reasons, and the second one was an
ordinary English verb colliding with a hostname pattern. Both times the failure
named the guard and the matching line rather than the mistake, because by then
the only context left was a regex.

Nothing here restates a pattern or an exclusion. Both are read out of the script,
because the duplicate is the trap: the guard's own comment records a global
rename that rewrote its pattern and left it refusing the wrong word for a day.
A copy in this file would have to be kept in step by whoever edits the script,
which is precisely the person who does not know this file exists.

The script is not in the snapshot, so these skip rather than fail when it is
absent. A test that reads a private-only file unconditionally breaks the publish
it protects, which is the failure the agent runbook records happening twice
in one day.
"""

import re
import unittest
from fnmatch import fnmatch
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PUBLISH = ROOT / "Scripts" / "publish-repo.sh"

# Read as text and scanned; anything else is what `grep -I` skips.
BINARY_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".icns", ".pdf", ".zip",
                   ".dmg", ".woff", ".woff2", ".ttf", ".otf", ".ico"}


def script() -> str:
    return PUBLISH.read_text(encoding="utf-8")


def excludes() -> list[str]:
    """The rsync excludes, taken from the EXCLUDES array and nowhere else.

    Scoped to that array on purpose. The guard commands further down carry
    `--exclude` flags of their own, and a findall over the whole script harvests
    those too, which quietly drops the files they name out of the scanned set
    for every guard rather than for the one guard that exempts them. That turned
    a narrow guard (d) exemption for `.gitignore` into an exemption from all
    four, and left two files that really do ship unchecked by the test that
    exists to check what ships.
    """
    text = script()
    start = text.index("EXCLUDES=(")
    end = text.index("\n)", start)
    return re.findall(r"--exclude='([^']*)'", text[start:end])


def guards() -> list[tuple[str, str, set[str], set[str]]]:
    """The scanning guards: (name, regex, excluded basenames, excluded dirs).

    Each is a `grep -rInE` over the mirror. The per-guard `--exclude` and
    `--exclude-dir` flags are part of the guard, not decoration: guard (a) skips
    the test tree on purpose because fixtures there carry private addresses, and
    reading that flag rather than assuming it is the difference between checking
    what the script checks and checking something adjacent to it.
    """
    text = script()
    found = []
    # The flags are not adjacent to the pattern: `"$MIRROR"` sits between them,
    # and on guard (a) they follow it on the next line. So the command is taken
    # whole, up to the `; then` that closes it, and the flags read out of that.
    for match in re.finditer(r"grep -rInE\s+(?:\"\$(\w+)\"|'((?:[^'\\]|\\.)*)')"
                             r"(.*?);\s*then", text, re.S):
        variable, literal, flags = match.groups()
        if variable:
            assignment = re.search(rf"^{variable}='((?:[^'\\]|\\.)*)'", text, re.M)
            if not assignment:
                continue
            pattern = assignment.group(1)
        else:
            pattern = literal
        names = set(re.findall(r"--exclude='?([^\s'\\]+)'?(?<!-dir)", flags))
        names = {n for n in names if not n.startswith("-dir=")}
        dirs = set(re.findall(r"--exclude-dir=([^\s'\\]+)", flags))
        found.append((f"guard {len(found) + 1}", pattern, names - dirs, dirs))
    return found


def published_files() -> list[Path]:
    """The files rsync would copy into the mirror, per the script's own excludes.

    rsync matches a pattern containing no slash against a basename at any depth,
    and one containing a slash against the path from the transfer root. Both
    forms are in the list, so both are honoured.
    """
    patterns = excludes()
    bare = [p for p in patterns if "/" not in p]
    rooted = [p for p in patterns if "/" in p]

    def excluded(rel: Path) -> bool:
        parts = rel.parts
        for pattern in bare:
            if any(fnmatch(part, pattern) for part in parts):
                return True
        text = rel.as_posix()
        for pattern in rooted:
            if fnmatch(text, pattern) or text.startswith(pattern.rstrip("/") + "/"):
                return True
        return False

    kept = []
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        rel = path.relative_to(ROOT)
        if excluded(rel) or path.suffix.lower() in BINARY_SUFFIXES:
            continue
        kept.append(path)
    return kept


class PublishGuardsTests(unittest.TestCase):
    def setUp(self) -> None:
        if not PUBLISH.is_file():
            self.skipTest("the publish script is not in this checkout, which is "
                          "the state its own excludes create")
        self.files = published_files()

    def test_the_excludes_and_the_guards_were_both_found(self) -> None:
        """A parser that silently reads nothing would pass every other test here."""
        self.assertGreater(len(excludes()), 20, "the exclude list did not parse")
        self.assertEqual(len(guards()), 4,
                         "expected the four scanning guards; the script's shape "
                         "has changed and this file is now reading it wrongly")

    def test_the_snapshot_would_carry_the_files_that_make_it_a_tap(self) -> None:
        shipped = {p.relative_to(ROOT).as_posix() for p in self.files}
        for required in ("Casks/seedbed.rb", "README.md", "LICENSE"):
            self.assertIn(required, shipped,
                          f"{required} would not be published, so the file set "
                          "computed here does not match what the script copies")

    def test_a_guard_exemption_does_not_become_a_global_one(self) -> None:
        """The guards carry their own `--exclude` flags, and they are not rsync's.

        Harvesting every `--exclude` in the script rather than the ones in the
        EXCLUDES array drops the files the guards exempt out of the scanned set
        entirely, so a file exempted from one guard stops being checked by the
        other three. Both files below really are published, so a run that does
        not scan them is measuring something adjacent to the snapshot.
        """
        shipped = {p.relative_to(ROOT).as_posix() for p in self.files}
        for path in (".gitignore", "tests/test_no_sibling_projects.py"):
            self.assertTrue(path in shipped,
                            f"{path} ships but is not in the scanned set, so a "
                            "per-guard exemption has widened into a global one")
        by_name = {name: skip for name, _, skip, _ in guards()}
        self.assertEqual(by_name["guard 1"], set(),
                         "the first guard exempts no file by name in the script")
        self.assertIn(".gitignore", by_name["guard 4"],
                      "the ignore-rule exemption belongs to the removed-refs guard")
        self.assertNotIn(".gitignore", by_name["guard 2"],
                         "the credential guard must still read .gitignore")

    def test_no_published_file_trips_a_snapshot_guard(self) -> None:
        offences = []
        for name, pattern, skip_names, skip_dirs in guards():
            expression = re.compile(pattern)
            for path in self.files:
                rel = path.relative_to(ROOT)
                if path.name in skip_names or skip_dirs & set(rel.parts):
                    continue
                try:
                    body = path.read_text(encoding="utf-8")
                except (UnicodeDecodeError, OSError):
                    continue
                for number, line in enumerate(body.splitlines(), 1):
                    hit = expression.search(line)
                    if hit:
                        offences.append(f"{name}: {rel}:{number} matched {hit.group(0)!r}")
        self.assertEqual(offences, [], "\n  " + "\n  ".join(offences[:25])
                         + f"\n  ({len(offences)} total) — the next publish would "
                         "abort naming the guard rather than the sentence")


if __name__ == "__main__":
    unittest.main()
