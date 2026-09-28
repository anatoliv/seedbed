cask "seedbed" do
  # "<short>,<build>": the appcast emits both sparkle:shortVersionString and
  # sparkle:version, and Homebrew's Sparkle livecheck strategy reports them as one
  # comma value. Pinning only the short version fails `brew audit --online` with
  # "differs from ... retrieved by livecheck" and breaks autobumping.
  version "0.1.19,20"
  sha256 "b5cef628fa7920e89bdd14684888beb6858600c458d071f9572ed8f5aff439ad"

  # No `verified:` parameter: Homebrew 6 deprecated it and `brew audit --online`
  # fails on one. It is unnecessary here anyway — the download host and the
  # homepage are the same domain, which is the case `verified:` existed to
  # declare. The sibling casks in this house still carry it and would fail the
  # same audit.
  url "https://seedbed.dev/Seedbed_#{version.csv.first}_universal.dmg"
  name "Seedbed"
  desc "Menu-bar front end for a git-backed prompt library"
  homepage "https://seedbed.dev/"

  # Seedbed auto-updates via Sparkle; track the signed appcast for new versions so
  # `brew livecheck` learns about a release from the same feed the app uses.
  livecheck do
    url "https://seedbed.dev/appcast.xml"
    strategy :sparkle
  end

  # Sparkle owns upgrades. Without this, `brew upgrade` and the in-app updater
  # would both try to replace the bundle.
  auto_updates true
  depends_on macos: :sonoma

  app "Seedbed.app"

  # NOTE: the MCP bearer tokens live in the login Keychain (service
  # "net.amnesia.seedbed.mcp") and are intentionally NOT removed by `zap` — a
  # reinstall should not silently invalidate the configuration you pasted into
  # Claude Code or Cursor. Remove them by hand from Keychain Access if you want
  # them gone. The writable library is local app data and is never touched by
  # `zap`. Deleting someone's prompts on uninstall would be data loss.
  zap trash: [
    "~/Library/Caches/net.amnesia.seedbed",
    "~/Library/HTTPStorages/net.amnesia.seedbed",
    "~/Library/Preferences/net.amnesia.seedbed.plist",
    "~/Library/Saved Application State/net.amnesia.seedbed.savedState",
  ]

  # Deliberately NOT `depends_on formula: "python@3.13"`. The app probes the usual
  # interpreter locations and takes the first that can import what it needs, so a
  # Mac with python.org's 3.12 or an Xcode 3.11 already satisfies it; declaring a
  # formula would install a second Python on those machines to no purpose. The
  # cost of leaving it out is that a Mac without Python opens the app but cannot
  # read its library. The menu's "No Python 3.11+ found." explains that failure.
  #
  # The caveats are GENERATED from macos/Packaging/dmg-readme.txt by
  # macos/Scripts/sync-cask.sh, so the DMG and the cask cannot drift into telling
  # people two different things. Edit that file, not this block.
  caveats <<~EOS
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
  EOS
end
