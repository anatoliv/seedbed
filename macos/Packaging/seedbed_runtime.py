"""Run the Python core shipped inside Seedbed.app against a writable library.

Python puts this script's directory ahead of the current working directory on
sys.path. This prevents an old promptlib copy in LibraryData from silently
overriding a newly installed app's code.
"""

from promptlib.cli import main

raise SystemExit(main())
