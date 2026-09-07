"""A bundle is stale when its sources differ in content, not when they are touched.

`macos/Scripts/check-release.sh` decided this by comparing source modification
times against the built binary's, and content never entered into it. Every
operation that rewrites a file with identical bytes therefore tripped the gate:
a restore from backup, a checkout, a formatter that changed nothing. The restore
case is not incidental here, it is the house pattern for proving a guard works,
so the two mechanisms were guaranteed to collide.

They did, on 2026-09-07. A source file was sabotaged and restored, the restored
copy hashed identical to the committed one, and the gate called the bundle
stale anyway. An auditor read that error as proof that committed UI had never
been built and sent a finished card back on the strength of it. The cheap cost
is a false alarm; the expensive one is the opposite direction, where a gate that
is known to cry wolf stops being read at all.

An mtime comparison also cannot see the failure that matters more: content
edited without the timestamp moving. That direction is unreachable by
timestamps and free with a hash.

So `make-app.sh` records a sha256 over the sources it compiled, as a second
field of the record that already carries the source commit, and the gate
compares digests. Three things are load-bearing:

1. **The digest answers content.** Same bytes, new mtime, same digest. Different
   bytes, same mtime, different digest. Neither is true of a timestamp.
2. **An absent digest falls back to the mtime check and never to a pass.** A
   bundle built before the record existed keeps exactly the behaviour it had.
   Failing open quietly is worse than the false alarm that prompted the change,
   because nothing says it happened.
3. **The two computations are the same computation.** The stamp and the check
   live in different scripts and are compared against each other, so a
   divergence makes every comparison meaningless while looking correct.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MACOS = REPO / "macos"
MAKE_APP = MACOS / "Scripts" / "make-app.sh"
CHECK_RELEASE = MACOS / "Scripts" / "check-release.sh"

KEY = "SeedbedSourceDigest"

# The value's shape, algorithm included. A bare hex string would compare unequal
# forever if the algorithm ever changed, and read as a permanently stale bundle.
VALUE_PATTERN = "^sha256:[0-9a-f]{64}$"

# The whole function, brace to brace. Anchored at the definition rather than
# matched loosely, so a second helper in either file cannot be picked up
# instead.
DIGEST_FUNCTION = re.compile(r"^source_digest\(\) \{\n(?:.*\n)*?\}$", re.MULTILINE)


def digest_function(script: Path) -> str:
    match = DIGEST_FUNCTION.search(script.read_text())
    if match is None:
        raise AssertionError(f"{script.name} defines no source_digest() function")
    return match.group(0)


class SourceCheck(unittest.TestCase):
    """Assertions against shell sources without dumping the whole file.

    `assertIn` against a 350-line script prints the script on failure, which
    buries the message saying what broke.
    """

    source: str

    def assertInSource(self, needle: str, why: str) -> None:
        self.assertTrue(needle in self.source, f"{why}\n  looked for: {needle!r}")


@unittest.skipUnless(MAKE_APP.exists() and CHECK_RELEASE.exists(),
                     "the macOS build scripts are not in this checkout")
class TheStampAndTheCheckComputeTheSameThing(unittest.TestCase):
    def test_the_two_functions_are_identical(self) -> None:
        """Not "both exist" — the same text.

        make-app.sh writes the value and check-release.sh recomputes it, and
        nothing compares the two implementations at run time. A file added to
        one side's set, or a different sort order, produces a mismatch on every
        release that looks exactly like a genuinely stale bundle.
        """
        self.assertEqual(
            digest_function(MAKE_APP), digest_function(CHECK_RELEASE),
            "the digest is computed differently in make-app.sh and "
            "check-release.sh, so the values they compare cannot agree")


@unittest.skipUnless(MAKE_APP.exists(), "make-app.sh is not in this checkout")
class TheDigestAnswersContentAndNotTimestamps(unittest.TestCase):
    """Runs the real function against a fixture tree.

    Asserting on the text of the pipeline would pass for a pipeline that hashes
    the wrong thing. These drive it.
    """

    @classmethod
    def setUpClass(cls) -> None:
        cls.function = digest_function(MAKE_APP)

    def setUp(self) -> None:
        self.tree = Path(tempfile.mkdtemp(prefix="seedbed-digest"))
        self.addCleanup(shutil.rmtree, self.tree, True)
        (self.tree / "Sources" / "Seedbed").mkdir(parents=True)
        (self.tree / "Sources" / "Seedbed" / "App.swift").write_text("let a = 1\n")
        (self.tree / "Sources" / "Seedbed" / "View.swift").write_text("let b = 2\n")
        (self.tree / "Package.swift").write_text("// swift-tools-version:5.9\n")

    def digest(self) -> str:
        runner = self.tree / "run-digest.sh"
        runner.write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\ncd \"$1\"\n"
            f"{self.function}\nsource_digest\n")
        out = subprocess.run(
            ["bash", str(runner), str(self.tree)],
            capture_output=True, text=True, check=True)
        value = out.stdout.strip()
        self.assertRegex(value, "^[0-9a-f]{64}$",
                         f"the digest is not a sha256: {value!r}")
        return value

    def test_a_file_rewritten_with_identical_bytes_keeps_the_digest(self) -> None:
        """The defect, in the form it actually occurred.

        Sabotage a source file, restore it from the backup, and the file comes
        back byte for byte with a later mtime. That must be indistinguishable
        from never having touched it, because it is.
        """
        before = self.digest()
        target = self.tree / "Sources" / "Seedbed" / "View.swift"
        original = target.read_text()
        target.write_text("let b = 999  // sabotage\n")
        target.write_text(original)
        os.utime(target, (target.stat().st_atime + 600, target.stat().st_mtime + 600))
        self.assertEqual(
            before, self.digest(),
            "restoring a file byte for byte moved the digest, so the gate would "
            "still call a byte-correct bundle stale")

    def test_a_changed_byte_moves_the_digest_even_with_the_mtime_held(self) -> None:
        """The direction an mtime comparison cannot cover at all.

        Timestamps are writable, and plenty of ordinary tooling preserves them.
        A gate that only reads them passes a binary built from different source.
        """
        target = self.tree / "Sources" / "Seedbed" / "View.swift"
        stamps = (target.stat().st_atime, target.stat().st_mtime)
        before = self.digest()
        target.write_text("let b = 3\n")
        os.utime(target, stamps)
        self.assertEqual(
            stamps[1], target.stat().st_mtime,
            "the fixture failed to hold the mtime, so this proves nothing")
        self.assertNotEqual(
            before, self.digest(),
            "a changed byte left the digest alone, so edited source would ship "
            "under a binary that never saw it")

    def test_a_rename_moves_the_digest(self) -> None:
        """Paths are hashed beside contents. A file moved between targets, or
        renamed so it stops being compiled, changes the binary while every
        surviving byte is identical."""
        before = self.digest()
        source = self.tree / "Sources" / "Seedbed" / "View.swift"
        source.rename(source.with_name("Renamed.swift"))
        self.assertNotEqual(
            before, self.digest(),
            "renaming a source file left the digest alone, so it hashes "
            "contents without regard to which file they are in")

    def test_a_deletion_moves_the_digest(self) -> None:
        before = self.digest()
        (self.tree / "Sources" / "Seedbed" / "View.swift").unlink()
        self.assertNotEqual(
            before, self.digest(),
            "deleting a source file left the digest alone")

    def test_package_swift_is_in_the_set(self) -> None:
        """It decides flags and dependencies, so a change there produces a
        different binary from identical sources — invisible to a check that
        only walks Sources."""
        before = self.digest()
        (self.tree / "Package.swift").write_text("// swift-tools-version:6.0\n")
        self.assertNotEqual(
            before, self.digest(),
            "Package.swift is outside the digest, so a dependency or flag "
            "change would leave a stale bundle looking current")


@unittest.skipUnless(MAKE_APP.exists(), "make-app.sh is not in this checkout")
class TheBuildRecordsTheDigest(SourceCheck):
    def setUp(self) -> None:
        self.source = MAKE_APP.read_text()

    def test_it_is_computed_before_the_build(self) -> None:
        """Otherwise it describes a tree that may have been edited while the
        compiler was running, and the bundle would vouch for source it does not
        contain."""
        computed = self.source.index('SOURCE_DIGEST="sha256:$(source_digest)"')
        built = self.source.index("swift build -c release")
        self.assertLess(
            computed, built,
            "the digest is computed after the build, so an edit made during "
            "the build is recorded as if it had been compiled")

    def test_it_is_written_into_the_built_bundle(self) -> None:
        self.assertInSource(
            f'Add :{KEY} string $SOURCE_DIGEST',
            "make-app.sh never writes the digest into the bundle, so the gate "
            "has nothing to read and falls back to mtimes forever")

    def test_it_is_read_back_out_of_the_bundle(self) -> None:
        """The working tree cannot testify about the artifact. A PlistBuddy
        write that silently did not take leaves an app that looks identical and
        carries nothing, which downstream reads as a bundle predating the
        record."""
        write = self.source.index(f"Add :{KEY} string")
        read = self.source.find(f"Print :{KEY}")
        self.assertNotEqual(
            -1, read, "make-app.sh never reads the recorded digest back")
        self.assertGreater(
            read, write,
            "make-app.sh reads the digest before writing it, so a failed write "
            "would pass unnoticed")

    def test_the_read_back_compares_against_what_was_computed(self) -> None:
        """Reading the field and not checking it is decoration."""
        self.assertInSource(
            '"$BAKED_DIGEST" != "$SOURCE_DIGEST"',
            "the value read back from the bundle is never compared against the "
            "digest this build computed")

    def test_every_build_is_stamped_not_only_a_distributable_one(self) -> None:
        """The commit stamp is refused from a dirty tree because it would name
        source the build does not contain. A digest cannot be wrong that way: it
        describes the bytes that were compiled. Gating it on the same condition
        would leave the ordinary build relying on the mtime comparison this
        exists to replace.
        """
        conditional = self.source.index('if [[ -n "${SEEDBED_BUILD_REF:-}" ]]; then')
        write = self.source.index(f"Add :{KEY} string")
        self.assertGreater(write, conditional)
        self.assertIn(
            "\nfi\n", self.source[conditional:write],
            "the digest is written inside the branch that only runs for a "
            "distributable build, so an ordinary bundle carries none")


@unittest.skipUnless(CHECK_RELEASE.exists(), "check-release.sh is not in this checkout")
class TheGateComparesContentAndFallsBackWhenItCannot(SourceCheck):
    def setUp(self) -> None:
        self.source = CHECK_RELEASE.read_text()

    def test_it_reads_the_digest_from_the_built_app(self) -> None:
        self.assertInSource(
            f"Print :{KEY}",
            "the release gate does not read the recorded digest out of the "
            "built bundle")

    def test_it_requires_the_canonical_shape(self) -> None:
        """A truncated or differently-computed value must take the fallback
        rather than be compared: it would never match, which reads as a
        permanently stale bundle and teaches everyone to ignore the gate."""
        self.assertInSource(
            VALUE_PATTERN,
            "the gate accepts a digest of any shape, so a malformed value is "
            "compared instead of being treated as absent")

    def test_it_compares_against_a_freshly_computed_tree_digest(self) -> None:
        self.assertInSource(
            'TREE_DIGEST="sha256:$(source_digest)"',
            "the gate never recomputes the digest over the working tree, so it "
            "compares the bundle's record against nothing")
        self.assertInSource(
            '"$BUNDLE_DIGEST" != "$TREE_DIGEST"',
            "the gate reads both digests and does not compare them")

    def test_a_mismatch_stops_the_release(self) -> None:
        mismatch = self.source.index('"$BUNDLE_DIGEST" != "$TREE_DIGEST"')
        self.assertIn(
            "exit 1", self.source[mismatch:mismatch + 700],
            "a source digest that disagrees with the bundle does not stop the "
            "release")

    def test_an_absent_digest_falls_back_to_the_mtime_check(self) -> None:
        """The property the whole fallback exists for, pinned at the seam that
        decides it.

        A bundle built before the record has no digest. If that read as
        "nothing to compare, therefore fine", every older bundle would silently
        start passing a check it was previously failing — worse than the false
        alarm this replaced, because it fails open and says nothing.

        Asserted against the text between the read and the mtime check rather
        than against the presence of either: both survive a change that puts the
        mtime check somewhere it can no longer run.
        """
        read = self.source.index('BUNDLE_DIGEST="')
        fallback = self.source.index("NEWEST_SOURCE=")
        self.assertLess(
            read, fallback,
            "the mtime check runs before the digest is read, so a bundle "
            "carrying a good digest is still judged on timestamps")
        between = self.source[read:fallback]
        self.assertIn(
            "\nelse\n", between,
            "the digest comparison has no else branch, so a bundle without a "
            "digest reaches no freshness check at all and passes")
        self.assertNotIn(
            "exit 0", between,
            "the gate can exit successfully between reading the digest and the "
            "mtime fallback, so an absent digest is a quiet pass")

    def test_the_fallback_still_stops_the_release(self) -> None:
        fallback = self.source.index("NEWEST_SOURCE=")
        self.assertIn(
            "exit 1", self.source[fallback:fallback + 900],
            "the mtime fallback reports a stale bundle and lets the release "
            "continue")


if __name__ == "__main__":
    unittest.main()
