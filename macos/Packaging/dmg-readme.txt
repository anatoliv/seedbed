Seedbed
=======

Drag Seedbed to Applications, then read this.

The app is a front end; it does not carry the prompts. Two things it needs on
this Mac:

1. The library. Seedbed reads and writes a git checkout of the seedbed
   repository, and it runs the Python package inside that checkout to do the
   work. Create Seedbed's common application-data folder, then clone the
   library there:

       mkdir -p "$HOME/Library/Application Support/Seedbed"
       git clone https://github.com/anatoliv/seedbed "$HOME/Library/Application Support/Seedbed/Library"

   On first load Seedbed points to ~/Library/Application Support/Seedbed/Library.
   An existing valid ~/Projects/seedbed checkout remains an automatic fallback
   for upgrades. Anywhere else is fine: menu bar icon, Settings, General,
   Choose. A folder without a promptlib directory in it is refused, and says why.

2. Python 3.11 or newer, for tomllib:

       brew install python

   Seedbed probes the usual locations and picks the first interpreter that can
   import what it needs. To point it at a specific one:

       defaults write net.amnesia.seedbed PythonPath /path/to/python3

Then launch it and press Option-Command-P. The icon lives in the menu bar; there
is no Dock tile.

Pasting into the app you came from needs the Accessibility permission, which
macOS asks for the first time you use it. Without it Seedbed copies to the
clipboard and tells you why it did not paste.

Crash reports are off. If you turn them on in Settings, General, Diagnostics,
they carry the stack trace and the versions, and never a prompt, a render, a
value you filled in, or an access token. Your home folder path is rewritten
to a tilde before anything leaves this Mac.
