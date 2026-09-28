Seedbed
=======

Drag Seedbed to Applications, then read this.

The app is a front end; it does not carry the prompts. Two things it needs on
this Mac:

1. The library. Seedbed keeps your writable prompts in
   ~/Library/Application Support/Seedbed/LibraryData, separate from Git. On
   first launch it copies an existing library or downloads the public starter
   snapshot. A fresh download needs an internet connection and Git. If that
   fails, clone the starter repository and relaunch:

       mkdir -p "$HOME/Library/Application Support/Seedbed"
       git clone https://github.com/anatoliv/seedbed "$HOME/Library/Application Support/Seedbed/Library"

   Seedbed copies that clone into LibraryData without changing it. An existing
   ~/Projects/seedbed checkout is copied the same way, including local edits.
   To use another library directly, choose it in Settings, General, Choose.

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
