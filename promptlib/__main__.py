"""Entry point for `python3 -m promptlib`.

The version check happens here, before any submodule is imported, because the
first thing a person does with a fresh checkout is run this — and on a Mac with
no Homebrew Python that means `/usr/bin/python3`, which is Xcode's 3.9. Without
the check, `store.py` reaches `import tomllib` eight frames down and prints a
`ModuleNotFoundError` traceback that says nothing about what to do. Found on a
second Mac on 2026-09-05, which is the first machine that ever ran this without
a 3.11+ interpreter already installed.

The macOS app never hits it: it probes candidate interpreters and picks one that
can import `tomllib`, so it fails with its own message instead. That is exactly
why this went unnoticed — the app was the only thing anyone had run.
"""

import sys

if sys.version_info < (3, 11):
    running = f"{sys.version_info.major}.{sys.version_info.minor}"
    sys.exit(
        f"seedbed needs Python 3.11 or newer; this is {running} ({sys.executable}).\n"
        "\n"
        "3.11 is where `tomllib` entered the standard library, and the prompt\n"
        "files are TOML-fronted, so there is no reading the library without it.\n"
        "\n"
        "  brew install python\n"
        "\n"
        "then run this again. If a newer Python is already installed but is not\n"
        "first on PATH, name it directly:\n"
        "\n"
        f"  /opt/homebrew/bin/python3 -m promptlib {' '.join(sys.argv[1:]) or 'list'}\n"
    )

from .cli import main

raise SystemExit(main())
