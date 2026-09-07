"""A distributed artifact must be able to say which revision produced it.

The estate rule these guards serve: every Cocoa task has to link the exact live
distribution to its source revision, and a local archive or a candidate tag
alone is insufficient. The reason is narrow and worth stating precisely. The
live 0.1.8 DMG is pinned by a sha256 in `Casks/seedbed.rb` and its appcast
enclosure is EdDSA-signed, so the bytes people download are provably the bytes
that were published. Neither fact says anything about *where those bytes came
from*. Integrity is not provenance. A tag does not close the gap either: a tag
names a commit, not an artifact, and the two agree only if nobody rebuilt.

`tests/test_crash_reporting.py` covers provider selection and the refusal to
carry two DSNs. This file covers the narrower claim underneath it: that an
artifact records which revision built it, that the record is written only from
a clean tree, and that the checks reading it fail closed. The two overlap by
design at `CrashReportingRelease`, which is where identity lives.

Three things are load-bearing and easy to lose in a refactor:

1. **Identity is not conditional on crash reporting.** A notarized DMG built
   with no DSN is still an artifact handed to a stranger, and it was the one
   artifact carrying no identity at all until this was widened.
2. **A commit stamp cannot detect a stale bundle.** An unrebuilt tree carries a
   perfectly truthful HEAD. The mtime staleness check is what covers freshness,
   so it must stay unconditional and ahead of the identity check.
3. **The bundle is re-read after it is written.** Everything else consults the
   working tree, which is the one witness that cannot testify about the artifact.
"""

from __future__ import annotations

import plistlib
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MACOS = REPO / "macos"
TRACKED_PLIST = MACOS / "Packaging" / "Info.plist"
MAKE_APP = MACOS / "Scripts" / "make-app.sh"
CHECK_RELEASE = MACOS / "Scripts" / "check-release.sh"
CONFIGURE = MACOS / "Scripts" / "configure-crash-reporting.sh"
VERIFY = MACOS / "Scripts" / "verify-identity.sh"

KEY = "CrashReportingRelease"

# The one shape that is an answer: 40 lowercase hex characters. Anything shorter
# is ambiguous as the repository grows, and an uppercase SHA compares unequal to
# every tool that prints one in lowercase.
SHA_PATTERN = "[0-9a-f]{40}"


class SourceCheck(unittest.TestCase):
    """Assertions against shell sources, without dumping the whole file.

    `assertIn` against a 250-line script prints the script on failure, which
    buries the message that says what broke.
    """

    source: str

    def assertInSource(self, needle: str, why: str) -> None:
        self.assertTrue(needle in self.source, f"{why}\n  looked for: {needle!r}")

    def assertNotInSource(self, needle: str, why: str) -> None:
        self.assertFalse(needle in self.source, f"{why}\n  found: {needle!r}")


@unittest.skipUnless(TRACKED_PLIST.exists(), "the macOS app is not in this checkout")
class TheTrackedPlistDeclaresTheKeyAndLeavesItEmpty(unittest.TestCase):
    def setUp(self) -> None:
        with TRACKED_PLIST.open("rb") as handle:
            self.plist = plistlib.load(handle)

    def test_the_key_is_declared(self) -> None:
        self.assertIn(
            KEY, self.plist,
            f"{KEY} is absent from the tracked Info.plist, so make-app.sh has "
            "nothing to set and a build would ship with no source identity")

    def test_it_is_empty_in_the_tree(self) -> None:
        """A committed value would be a claim the tree makes about itself.

        It would also be wrong the moment anyone committed again, and wrong in
        the direction that looks right — a plausible SHA naming the wrong
        revision is worse than no SHA at all.
        """
        self.assertEqual(
            "", self.plist.get(KEY, ""),
            f"{KEY} carries a value in the tracked plist. It must be injected "
            "at package time, or it will be stale")


@unittest.skipUnless(MAKE_APP.exists(), "make-app.sh is not in this checkout")
class TheBuildRecordsTheRevision(SourceCheck):
    def setUp(self) -> None:
        self.source = MAKE_APP.read_text()

    def test_a_supplied_revision_is_checked_like_any_other(self) -> None:
        """Regression: the exploit that got past every check here.

            touch DIRT.tmp
            SEEDBED_BUILD_REF=$(git rev-parse HEAD) Scripts/make-app.sh

        An ordinary dev build with the variable exported entered none of the
        branches that guard a stamp, and still got one — a bundle naming a
        commit while containing uncommitted work. Asking for a revision to be
        recorded is what triggers the checks, however it is asked for.
        """
        self.assertInSource(
            '|| -n "${SEEDBED_BUILD_REF:-}" ]]; then',
            "a caller-supplied revision skips the clean-tree and shape checks, "
            "so a dev build can stamp an origin nothing verified")

    def test_a_notarized_build_requires_identity_even_without_reporting(self) -> None:
        """Identity is a property of the artifact, not of crash reporting.

        Gating it on a configured provider left the DMG built without a DSN as
        the one artifact nobody could interrogate later — the exact case the
        estate rule is about.
        """
        self.assertInSource(
            '"$REPORTING_PROVIDER" != "none" || -n "${NOTARY_PROFILE:-}"',
            "make-app.sh requires a source commit only for reporting builds, "
            "so a notarized build with no DSN would carry no identity")

    def test_it_refuses_an_uncommitted_tree(self) -> None:
        """A stamp from a dirty tree names a revision the build was not made
        from: authoritative-looking and false, and unverifiable after the fact.
        """
        self.assertInSource(
            "git status --porcelain --untracked-files=normal",
            "make-app.sh does not inspect the working tree")
        self.assertInSource(
            "error: refusing a distributable build from uncommitted source",
            "make-app.sh does not refuse a build from an uncommitted tree")

    def test_the_refusal_is_not_a_warning(self) -> None:
        """A warning still produces the artifact, and the artifact is the
        problem: nothing downstream can tell it apart from a good one."""
        refusal = self.source.index("refusing a distributable build")
        tail = self.source[refusal:refusal + 400]
        self.assertIn(
            "exit 1", tail,
            "the uncommitted-tree check does not stop the build")

    def test_it_validates_the_shape(self) -> None:
        """Missing, abbreviated, uppercase and non-hex must all be refused."""
        self.assertInSource(
            f"^{SHA_PATTERN}$",
            "make-app.sh does not pin the SHA to 40 lowercase hex characters, "
            "so an abbreviated or uppercase revision would be accepted")

    def test_it_reads_the_value_back_out_of_the_built_bundle(self) -> None:
        """The working tree cannot testify about the artifact.

        The injection is a PlistBuddy write into a copied file. If it silently
        does not happen the app looks identical and carries an empty key, so
        the only trustworthy assertion reads the bundle rather than the tree.
        """
        write = self.source.index("Scripts/configure-crash-reporting.sh \"$APP\"")
        read = self.source.find(f"Print :{KEY}")
        self.assertNotEqual(
            -1, read, "make-app.sh never reads the recorded release back")
        self.assertGreater(
            read, write,
            "make-app.sh reads the release before writing it, so a failed "
            "injection would pass unnoticed")

    def test_the_read_back_compares_against_what_was_asked_for(self) -> None:
        """Reading the field and not checking it is decoration."""
        self.assertInSource(
            '"$BAKED_RELEASE" != "net.amnesia.seedbed@$SEEDBED_BUILD_REF"',
            "the value read back from the bundle is never compared against "
            "the revision this build was supposed to record")


@unittest.skipUnless(CONFIGURE.exists(), "configure-crash-reporting.sh is not here")
class IdentityIsRecordedWithOrWithoutAProvider(SourceCheck):
    def setUp(self) -> None:
        self.source = CONFIGURE.read_text()

    def test_a_non_reporting_build_still_records_its_revision(self) -> None:
        none_branch = self.source[self.source.index('if [[ "$provider" == "none" ]]'):]
        none_branch = none_branch[:none_branch.index("exit 0")]
        self.assertIn(
            f'set_plist {KEY} "net.amnesia.seedbed@$SEEDBED_BUILD_REF"', none_branch,
            "a build with no provider blanks its release, so a notarized DMG "
            "built without a DSN carries no source identity")

    def test_it_still_refuses_a_malformed_revision(self) -> None:
        self.assertInSource(
            f"^{SHA_PATTERN}$",
            "the configurator accepts a revision that is not a full "
            "lowercase-hex SHA")

    def test_it_still_refuses_two_providers(self) -> None:
        """Rollback has to be a rebuild and swap that cannot become dual-send.

        Not this file's change, but it is the invariant everything else here
        sits on top of, and a refactor of provider selection could drop it
        without any other test noticing.
        """
        self.assertInSource(
            "refusing dual-send",
            "the configurator no longer refuses a build carrying both Crashbox "
            "and hosted-Sentry inputs")

    def test_it_does_not_inspect_the_working_tree(self) -> None:
        """Cleanliness is make-app.sh's question, not this script's.

        Regression, in the other direction. Putting the check here made a unit
        test of the configurator depend on whether the repository happened to
        have uncommitted work, which is its normal state while developing:
        test_crash_reporting.py drives this script with a synthetic ref and a
        fixture bundle, and started failing for a reason that had nothing to do
        with what it was testing. The script writes what it is told; the build
        decides whether telling it is legitimate.
        """
        self.assertNotInSource(
            "git status",
            "the configurator inspects the working tree, which makes calling "
            "it depend on repository state it should not care about")

    def test_an_absent_revision_leaves_the_field_empty(self) -> None:
        """A local dev build has no revision worth asserting, and inventing a
        placeholder would group every anonymous build under one heading."""
        self.assertInSource(
            f'set_plist {KEY} ""',
            "an unidentified build writes something other than an empty "
            "release, so absence and a real answer look alike")


@unittest.skipUnless(CHECK_RELEASE.exists(), "check-release.sh is not in this checkout")
class TheGateRefusesAnArtifactWithoutIdentity(SourceCheck):
    def setUp(self) -> None:
        self.source = CHECK_RELEASE.read_text()

    def test_it_reads_the_release_from_the_built_app(self) -> None:
        self.assertInSource(
            f"Print :{KEY}",
            "the release gate does not read the recorded release out of the "
            "built bundle")
        self.assertInSource(
            '"$APP/Contents/Info.plist"',
            "the gate reads a plist that is not the built bundle's")

    def test_the_identity_check_is_not_conditional_on_reporting(self) -> None:
        """Every release must be attributable, not only a reporting one."""
        identity = self.source.index("BUNDLE_RELEASE=")
        provider_gate = self.source.index('if [[ "$REPORTING_PROVIDER" != "none" ]]')
        self.assertLess(
            identity, provider_gate,
            "the identity check sits inside or after the provider-conditional "
            "block, so a release built without a DSN would skip it")

    def test_it_requires_the_canonical_shape(self) -> None:
        self.assertInSource(
            f"^net\\.amnesia\\.seedbed@{SHA_PATTERN}$",
            "the release gate accepts a malformed or absent revision")

    def test_it_requires_the_bundle_to_match_head(self) -> None:
        """Otherwise a stale build ships under a fresh tag."""
        self.assertInSource(
            "git rev-parse HEAD",
            "the gate never compares the bundle's recorded origin against the "
            "commit about to be tagged")

    def test_the_mtime_staleness_check_is_still_unconditional(self) -> None:
        """The identity record does not answer freshness and must not replace
        the check that does.

        A commit stamp cannot detect a stale bundle: an unrebuilt tree carries
        a perfectly truthful HEAD. If this check ever became conditional on the
        record, bundles predating it would silently stop being checked at all,
        which is strictly worse than the false alarm that motivated changing it.
        """
        self.assertInSource(
            '-newer "$APP/Contents/MacOS/Seedbed"',
            "the mtime staleness check is gone")
        staleness = self.source.index("NEWEST_SOURCE=")
        identity = self.source.index("BUNDLE_RELEASE=")
        self.assertLess(
            staleness, identity,
            "the staleness check now runs after the identity check, so it can "
            "be short-circuited by an identity failure")
        guard = self.source[:staleness].rsplit("\n\n", 1)[-1]
        self.assertNotIn(
            KEY, guard,
            "the mtime staleness check has been made conditional on the "
            "identity record")


@unittest.skipUnless(VERIFY.exists(), "verify-identity.sh is not in this checkout")
class AnyArtifactCanBeInterrogatedWithoutABuild(SourceCheck):
    """The check that answers the question for a DMG off the live site.

    Distinct from verify-reporting-artifact.sh, which needs the unpacked app
    and its dSYM — neither of which exists once the artifact has been handed to
    someone.
    """

    def setUp(self) -> None:
        self.source = VERIFY.read_text()

    def test_it_is_executable(self) -> None:
        self.assertTrue(
            VERIFY.stat().st_mode & 0o111,
            "verify-identity.sh is not executable, so the documented "
            "invocation does not work")

    def test_it_handles_a_dmg(self) -> None:
        """A downloaded image is the case that matters; an unpacked .app is not
        what anyone has when they are asking which revision they are running."""
        self.assertInSource(
            "hdiutil attach",
            "verify-identity.sh cannot inspect a DMG, which is the form a live "
            "artifact actually arrives in")

    def test_it_mounts_read_only(self) -> None:
        self.assertInSource(
            "-readonly",
            "inspecting an artifact must not be able to modify it")

    def test_it_needs_no_dsym(self) -> None:
        """Its whole reason to exist is the artifact you were handed."""
        self.assertNotInSource(
            "dwarfdump",
            "verify-identity.sh requires debug symbols, which do not travel "
            "with a DMG — that is verify-reporting-artifact.sh's job")

    def test_it_extracts_the_commit_rather_than_assuming_it(self) -> None:
        """Named against `$COMMIT` specifically, not against the SHA pattern
        anywhere in the file.

        The pattern also appears in the check on the caller-supplied expected
        SHA further up, so a looser assertion stays green even when the guard
        on the extracted commit is gone entirely. That is the same shape of
        false pass already found once in this suite: a guard that holds for
        the wrong reason.
        """
        self.assertInSource(
            f'"$COMMIT" =~ ^{SHA_PATTERN}$',
            "the verifier does not validate the extracted commit, so a "
            "release string in another shape would be truncated into "
            "something that looks like an answer")

    def test_it_exits_nonzero_without_identity(self) -> None:
        self.assertInSource(
            "error: this artifact carries no usable source identity",
            "verify-identity.sh does not fail loudly on an artifact with no "
            "recorded revision, so it could be mistaken for a pass")

    def test_it_never_prints_the_dsn(self) -> None:
        """It is run against artifacts and its output gets pasted into
        issues."""
        self.assertNotInSource(
            "CrashReportingDSN",
            "verify-identity.sh reads the DSN, which must never reach its "
            "output")
