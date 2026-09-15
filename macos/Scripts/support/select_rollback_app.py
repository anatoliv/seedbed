#!/usr/bin/env python3
"""Select exactly one top-level, non-symlink Seedbed.app from a mounted DMG."""

from __future__ import annotations

import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("error: usage: select_rollback_app.py <mountpoint>.", file=sys.stderr)
        return 1
    root = Path(sys.argv[1])
    try:
        apps = [entry for entry in root.iterdir() if entry.name.endswith(".app")]
    except OSError:
        print("error: the rollback DMG mountpoint could not be enumerated.", file=sys.stderr)
        return 1
    if (
        len(apps) != 1
        or apps[0].name != "Seedbed.app"
        or apps[0].is_symlink()
        or not apps[0].is_dir()
    ):
        print(
            "error: the rollback DMG must contain exactly one top-level "
            "non-symlink Seedbed.app directory.",
            file=sys.stderr,
        )
        return 1
    print(apps[0])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
