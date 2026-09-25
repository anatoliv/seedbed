#!/usr/bin/env python3
"""Fail-closed metadata checks for one retained Seedbed rollback artifact."""

from __future__ import annotations

import argparse
import hashlib
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

CRASHBOX_DSN = re.compile(
    r"https://[A-Za-z0-9._~-]+@ingest\.crashbox\.dev/[0-9]+"
)
EXECUTABLE_NAME = re.compile(r"[A-Za-z0-9._-]+")
RELEASE_IDENTITY = re.compile(r"net\.amnesia\.seedbed@([0-9a-f]{40})")


def refuse(reason: str) -> None:
    raise ValueError(reason)


def git(repo: Path, *args: str) -> bytes:
    try:
        return subprocess.run(
            ["git", "-C", os.fspath(repo), *args],
            check=True,
            capture_output=True,
        ).stdout
    except subprocess.CalledProcessError:
        refuse("the expected rollback commit could not be read from this Seedbed checkout")


def source_digest(repo: Path, commit: str) -> str:
    listed = git(
        repo,
        "ls-tree",
        "-r",
        "--name-only",
        commit,
        "--",
        "macos/Sources",
        "macos/Package.swift",
    ).decode("utf-8").splitlines()
    paths = sorted(
        path for path in listed
        if path == "macos/Package.swift"
        or path.startswith("macos/Sources/") and path.endswith(".swift")
    )
    if "macos/Package.swift" not in paths or not any(
        path.startswith("macos/Sources/") for path in paths
    ):
        refuse("the expected commit has no complete Seedbed source tree")
    lines = bytearray()
    for path in paths:
        content = git(repo, "show", f"{commit}:{path}")
        relative = path.removeprefix("macos/")
        lines.extend(f"{hashlib.sha256(content).hexdigest()}  {relative}\n".encode())
    return f"sha256:{hashlib.sha256(lines).hexdigest()}"


def plist_at_commit(repo: Path, commit: str) -> dict[str, object]:
    try:
        return plistlib.loads(git(repo, "show", f"{commit}:macos/Packaging/Info.plist"))
    except (plistlib.InvalidFileException, ValueError):
        refuse("the expected commit has no readable Seedbed packaging identity")


def text(info: dict[str, object], key: str) -> str:
    value = info.get(key)
    return value if isinstance(value, str) else ""


def build_commit_under_tag(repo: Path, info: dict[str, object], tag_commit: str) -> str:
    """The commit the artifact was built from, bound to the tag it shipped as.

    make-app.sh stamps HEAD at build time, and the cask and site pin commit
    that the tag points at comes after the build, so a tagged release's own
    DMG never names the tag commit. The artifact's baked commit is accepted
    only when it is the tag commit or one of its ancestors, and only when the
    tag's Seedbed sources are byte-for-byte the ones that commit built.
    """
    match = RELEASE_IDENTITY.fullmatch(text(info, "CrashReportingRelease"))
    if not match:
        refuse("the rollback artifact has the wrong source release identity")
    build_commit = match.group(1)
    git(repo, "cat-file", "-e", f"{build_commit}^{{commit}}")
    ancestry = subprocess.run(
        ["git", "-C", os.fspath(repo), "merge-base", "--is-ancestor",
         build_commit, tag_commit],
        capture_output=True,
        check=False,
    )
    if ancestry.returncode != 0:
        refuse(
            f"the rollback artifact was built from {build_commit}, which is not "
            f"the rollback tag commit {tag_commit} or an ancestor of it"
        )
    if source_digest(repo, build_commit) != source_digest(repo, tag_commit):
        refuse(
            f"the Seedbed sources changed between the artifact's build commit "
            f"{build_commit} and the rollback tag commit {tag_commit}"
        )
    return build_commit


def validate(
    repo: Path,
    app: Path,
    expected_version: str,
    expected_build: str,
    expected_commit: str,
    from_tag: bool = False,
) -> str:
    if not re.fullmatch(r"[0-9a-f]{40}", expected_commit):
        refuse("the expected rollback commit is not 40 lowercase hex characters")
    git(repo, "cat-file", "-e", f"{expected_commit}^{{commit}}")

    if app.name != "Seedbed.app" or app.is_symlink() or not app.is_dir():
        refuse("the rollback app must be a non-symlink Seedbed.app directory")
    contents = app / "Contents"
    plist = contents / "Info.plist"
    macos = contents / "MacOS"
    if (
        contents.is_symlink()
        or not contents.is_dir()
        or plist.is_symlink()
        or not plist.is_file()
        or macos.is_symlink()
        or not macos.is_dir()
    ):
        refuse("the rollback artifact is not a contained Seedbed app bundle")
    try:
        info = plistlib.loads(plist.read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError):
        refuse("the rollback artifact has no readable Seedbed Info.plist")

    if from_tag:
        expected_commit = build_commit_under_tag(repo, info, expected_commit)

    committed = plist_at_commit(repo, expected_commit)
    if text(committed, "CFBundleShortVersionString") != expected_version:
        refuse("the expected version does not match the expected commit")
    if text(committed, "CFBundleVersion") != expected_build:
        refuse("the expected build does not match the expected commit")
    committed_executable = text(committed, "CFBundleExecutable")
    if not committed_executable:
        refuse("the expected commit has no executable identity")

    if text(info, "CFBundleIdentifier") != "net.amnesia.seedbed":
        refuse("the rollback artifact is not net.amnesia.seedbed")
    if text(info, "CFBundleShortVersionString") != expected_version:
        refuse("the rollback artifact has the wrong short version")
    if text(info, "CFBundleVersion") != expected_build:
        refuse("the rollback artifact has the wrong build number")
    if text(info, "CrashReportingRelease") != f"net.amnesia.seedbed@{expected_commit}":
        refuse("the rollback artifact has the wrong source release identity")
    if text(info, "SeedbedSourceDigest") != source_digest(repo, expected_commit):
        refuse("the rollback artifact source digest does not match the expected commit")

    provider = text(info, "CrashReportingProvider")
    dsn = text(info, "CrashReportingDSN")
    environment = text(info, "CrashReportingEnvironment")
    if provider == "crashbox":
        if not CRASHBOX_DSN.fullmatch(dsn):
            refuse("the rollback artifact does not name the canonical Crashbox DSN")
        if environment != "production":
            refuse("the rollback Crashbox environment is not production")
    elif provider == "":
        if dsn or environment:
            refuse("a reporting-disabled rollback retains reporting configuration")
    elif provider == "hosted-sentry":
        refuse("the rollback artifact reports to hosted Sentry")
    else:
        refuse("the rollback artifact carries an unknown reporting provider")

    executable_name = text(info, "CFBundleExecutable")
    if (
        executable_name != committed_executable
        or not EXECUTABLE_NAME.fullmatch(executable_name)
        or executable_name in {".", ".."}
    ):
        refuse("the rollback artifact has an unsafe executable name")
    executable = macos / executable_name
    if executable.is_symlink() or not executable.is_file():
        refuse("the rollback artifact has no contained non-symlink executable")
    return expected_commit


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("repo", type=Path)
    parser.add_argument("app", type=Path)
    parser.add_argument("expected_version")
    parser.add_argument("expected_build")
    parser.add_argument("expected_commit")
    parser.add_argument(
        "--tag-commit",
        action="store_true",
        help="expected_commit is the rollback tag's commit; the artifact's own "
        "build commit must be it or an ancestor with identical Seedbed sources",
    )
    args = parser.parse_args()
    try:
        build_commit = validate(
            args.repo.resolve(),
            args.app,
            args.expected_version,
            args.expected_build,
            args.expected_commit,
            args.tag_commit,
        )
    except ValueError as error:
        print(f"error: {error}.", file=sys.stderr)
        return 1
    print(build_commit)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
