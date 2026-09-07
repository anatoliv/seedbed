# Seedbed — the app

The prompt library as a macOS menu-bar app. Press **⌥⌘P** anywhere, type to
filter, press **⏎** or **⌘1–9** to put a model's tailored prompt on the
clipboard, then paste it into whatever agent you are talking to.

    Scripts/make-app.sh && open build/Seedbed.app

No Dock icon. Right-click (or control-click) the menu-bar icon for the full
menu: what it is doing, the things you do most, what you configure, then About,
Check for Updates…, Getting Started, Help and Quit. The panel
is resizable and remembers its size and position.

### The two icon drawings

They are optical variants of one identity, not two competing icons. The menu
bar uses the single-leaf template from `assets/brand/seedbed-menu-template.svg`:
at 18 pt, the full two-leaf/text-bed mark reads as a rabbit with a square head.
Finder, app-bundle and larger marketing contexts use the complete terracotta
sprout-and-text-bed icon. The authoritative placement matrix and export command
are in `assets/brand/README.md`; do not substitute an SF Symbol except as the
existing missing-resource fallback.

Pinned prompts always sort first, whatever the sort mode — pinning is the manual
override, and a sort that could bury a pinned prompt would make pinning
pointless. Copy counts are machine-local (gitignored), so "most used" reflects
how you work on *this* machine; pins are in the seed files and sync with them.

## Keys

| Key | Does |
|---|---|
| ⌥⌘P | show or hide the panel, over any app, on any Space |
| type | filter by title, body, id or tag |
| ↑ ↓ | move |
| ⏎ | copy **and paste** into the app you came from |
| ⇧⏎ | copy only, no paste |
| ⌘1–9 | copy and paste for that model — building it first if never rendered |
| ⇧⌘1–9 | copy only, for that model |
| ⎋ or click away | close |
| ⌘D | pin the selected prompt to the top (travels with the library) |
| ⌘R | rebuild the selected prompt for all its models |
| ⇧⌘R | rebuild every stale prompt, re-pulling vendor guidance first |
| ⌥⌘1–9 | rebuild just that one model |
| ⌘E | edit the selected prompt in the library window |
| ⌘⌫ | delete the selected prompt, after confirming what it destroys |
| ⌘S | cycle the sort: name, most used, last refreshed, recent |

## Actions on the row

Every one of those acts on the **selected** prompt. Hovering a row instead
reveals the same actions as icons on that row, and they act on the row under
the pointer without moving the selection — copy, paste into the app you came
from, rebuild, edit in the library, pin, delete.

The library window's sidebar rows carry the same strip, minus the two that
cannot mean anything there: editing (you are already in the editor) and pasting
into the app you came from (that app is the one the panel was summoned over,
and the library window was not summoned over anything). A button that does not
apply is hidden rather than greyed out.

## Pasting

By default a copy is pasted straight into the app that was frontmost when you
summoned the panel, so the whole interaction is ⌥⌘P, type, ⏎. Hold ⇧ to copy
without pasting, or turn it off in the menu-bar menu.

This needs **Accessibility** permission (System Settings → Privacy & Security →
Accessibility), because sending ⌘V to another process is exactly what that
permission governs. Until it is granted the app copies and tells you why it did
not paste.

macOS ties that permission to the app's code signature, so `make-app.sh` signs
with a real Developer ID when one is present: an ad-hoc signature changes on
every build and the permission would have to be granted again each time. There
is no notarization here — this is a locally built, locally run tool.

## Try it

`Fix a bug in a project` is pinned at the top and carries two placeholders.
Copy it and the form asks for `BUG` and `PROJECT`; `PROJECT` already has a
history to pick from. The copied text reads "Fix <your bug> in <your project>
and add a regression test…". Delete `.variables.json` to clear that history.

## Values you fill in

A tailored prompt usually carries `{{PLACEHOLDER}}` tokens — the enhancer keeps
the ones you wrote and adds its own (`{{BUG_REPORT}}`, `{{CODE}}`). Copying a
prompt that has any opens a small form first: one field per placeholder, each
with a history menu of values you have used before, pre-filled with the most
recent. Blank fields stay as `{{NAME}}` in the copied text rather than
disappearing, so a gap is visible rather than silent.

Those values live in a gitignored `.variables.json`, the same call as the copy
counter: a tracked file rewritten on every fill means a diff per copy, a merge
conflict whenever two machines use the same prompt, and project names in a
synced file by default.

## The MCP server

Menu bar icon, then **Settings**, then **MCP**. Switch it on and press *Copy
configuration*;
paste the result into Claude Code, Cursor or Claude Desktop. The snippet is a
standard `mcpServers` entry carrying the URL and the bearer token, and the URL
takes no path after the port.

| Tool | Does |
|---|---|
| `find_prompt` | search by description, with the reason for the match; pass `model` to get that model's render in the same answer |
| `get_prompt` | one prompt by id, as the seed or as a model's tailored version |
| `list_prompts` | everything, with each render's state |
| `list_models` | the target models, which are the ids the other tools accept |
| `build_prompt` | generate or regenerate one render. **Spends an LLM call** |

Clients that speak MCP prompts also see every prompt under `prompts/list` and
can pull one with `prompts/get`.

**Security.** The listener binds to loopback only, so nothing on the network can
connect, and every request must carry the token as well. Both, not either. There
is no remote access switch and no tunnel. A **read-only token** is issued
alongside the full one: it can search and read but cannot call `build_prompt`,
and clients holding it are not even shown that tool. Both tokens live in the
login Keychain rather than the preferences file.

Three things that refuse a request, each with a reason in the response body:
a wrong token (and after ten of those, a lockout that doubles from one minute to
fifteen, while a correct token is still always served); a `Host` or `Origin` that
is not this Mac, which is what stops a web page pointing its own domain here and
reading the library through your browser; and a stray path on the URL.

Settings live in `MCPEnabled` and `MCPPort` under `net.amnesia.seedbed`; the
default port is 8789. Upgrades migrate the former 8787 default once, while a
different port chosen in Settings is preserved.

## The library window

⌘L from the panel, or menu-bar icon → **Prompt Library…**. A proper window for
the slower work the HUD is wrong for:

- **Add** a prompt with **+** at the bottom of the sidebar (or the **New**
  button): it creates one, selects it, and drops you into Edit. **−** deletes
  the selected prompt and everything generated from it, after confirming.
- **Browse** every prompt with its model count, use count, pin, and a dot when
  something is stale. Hover a row for copy, rebuild, pin and delete on the row
  itself.
- **Edit** the title, the prompt text and which models it is built for. Saving
  is explicit, and changing the text warns you that it makes every render of it
  stale before you press it.
- **Compare** what each model made of the same seed, side by side, with each
  column's word count, date, placeholders, and its own Copy and Rebuild. Columns
  share the window width and only scroll when they genuinely cannot fit. One
  column per model *the prompt is built for* — to see more, tick more models in
  the Edit tab.
- **Filter** by category or search, in the sidebar.

## Which model builds your prompts

**Models → Build with…**, or `promptlib enhancer show|set|test|presets`.

Mirrors Reference's Settings → AI:

| | |
|---|---|
| Provider presets | 14, filling endpoint + model + auth in one pick |
| Auth modes | Claude Code CLI (no key), Anthropic SDK, API key / local server, Azure `api-key` header |
| Endpoint + model | free-form, with the endpoint rule below |
| API key | login Keychain (`promptlib-enhancer`), never a file, never echoed |
| Fallback | endpoint + model + key, tried **once** on a retryable failure |
| Timeout | a build is one long request |
| Test | saves, then does a real round trip |

**The endpoint rule:** https anywhere, plain http only to localhost or a private
address. A key sent over http to a public host is readable in transit; a local
model server has no certificate. So the rule is about *where*, not the scheme
alone.

**The fallback fires on a rate limit, a 5xx or a network failure — not on a 401
or a 404**, because the same request body would fail the same way at a second
endpoint. One attempt, not a loop.

**Not implemented: ChatGPT sign-in (Codex OAuth).** The preset and auth mode are
present and say so plainly rather than failing at build time. Porting it means
PKCE, a loopback callback server and Keychain token refresh — it exists in
Reference's Swift and would need a Python port to run inside the build
pipeline. Use an API key, a local server, or the CLI backend meanwhile.

## Adding and configuring models

**Models → Add or configure models…** in the library window. A model here is a
prompting profile, not an API connection: an id, a display name, a family, the
documentation URLs or local files that say how to prompt it, and free-text notes
that are always part of its guidance. Adding one causes no vendor call — the
enhancer is configured separately — so it is cheap and reversible. Removing one
keeps its renders on disk, so re-adding it costs nothing.

`models.toml` stays hand-editable: a save rewrites the model blocks and keeps
the explanatory header above them.

## Categories

A prompt can carry a category (Edit tab). It shows under the title in both the
picker and the library, narrows the sidebar's filter, and is matched by search
in both windows.

## Showing fewer models

**Models** menu in the library window's header, or menu-bar icon → **Models
shown…**. Working with two models today should not mean scrolling past seven.

It is a view filter only: `models.toml` and every render are untouched, ⌘1–9
renumber to what is visible, and **Show all** brings everything back. One
setting drives both the picker and the compare columns — three separate model
lists was one too many to keep straight. Which models a *prompt* is built for is
a different thing, and lives in the Edit tab.

## How it fits together

**This app is a front end. `promptlib` (Python, in the parent directory) owns
the library.** The app shells out to it for three things: `json` to list,
`show` to fetch a rendered prompt, `build` to render a missing one. Staleness,
the guidance cache and the enhancer therefore have exactly one implementation,
shared with the CLI and the web UI. Parsing the markdown here as well would
guarantee the two drift.

Two consequences worth knowing:

- **It needs Python 3.11 or newer** (for `tomllib`). The app does not trust
  `PATH` — an app launched from Finder gets a minimal one, where `python3` is
  Xcode's 3.9 and every call fails. It probes known locations and picks the
  first interpreter that can actually `import tomllib`. Override with:
  `defaults write net.amnesia.seedbed PythonPath /path/to/python3`
- **It needs the library checkout.** A first load points to
  `~/Library/Application Support/Seedbed/Library`; change it from the menu-bar
  menu. A valid legacy `~/Projects/seedbed` checkout remains an automatic
  fallback for upgrades.

## Check for Updates…

There is no Sparkle feed. "An update" here means the git repository has commits
this build does not, so that is what the menu item checks — `git fetch`, then
how far behind the tracking branch you are — and it prints the commits and the
commands that take them.

Which commands depends on where this copy came from, because the answer differs
and giving the wrong one is worse than giving none. A copy built out of the
checkout is rebuilt with `make-app.sh`; a copy installed from a release DMG has
no Swift toolchain to rebuild with, so it is told that pulling updates the
library — which is what most commits change — and that the app itself changes
when a newer DMG is installed over it. `Updates.wasBuiltFrom` decides by asking
whether the running bundle sits inside the library checkout.

## Signing

`make-app.sh` signs with the Developer ID identity when one is in the keychain,
and falls back to ad-hoc with a printed warning about the cost. The identity is
not about distribution: macOS ties the Accessibility permission to the code
signature, and an ad-hoc signature changes on every build, so pasting into the
frontmost app would break after every rebuild.

`NOTARY_PROFILE=<profile> Scripts/make-app.sh` also notarizes and staples the
bundle. `Scripts/release.sh` does that and packages the result.

## Distribution — installing on a Mac that did not build this

    Scripts/release.sh

Builds, signs, notarizes and staples the `.app`, packages it into a DMG with an
`/Applications` drop target, notarizes and staples the DMG too, and prints the
sha256. It discovers the Developer ID identity and the notarytool profile from
the keychain; the notarytool credential is per Apple account rather than per
app, so an existing profile from another project is the right one to use. The
result is `dist/Seedbed_<version>_universal.dmg`, Intel and Apple silicon in one
bundle.

The `.app` is stapled as well as the DMG, deliberately. Stapling only the image
leaves the copy dragged into `/Applications` needing to reach Apple to be
verified, which fails on a Mac that is offline or behind a filter.

**The DMG is not the whole install.** This app is a front end; the prompts and
the code that renders them are the checkout. On the other Mac you also need a
clone of this repository and Python 3.11+, and a first load points at
`~/Library/Application Support/Seedbed/Library` unless Settings → General →
Choose says otherwise. A valid legacy `~/Projects/seedbed` checkout is still
recognized. That is
why `Packaging/dmg-readme.txt` rides along inside the image as *Before you start*.

Guards worth knowing about before the first run, all of them ported from
Reference after they earned their place there:

- **A Seedbed running out of this repo is fatal.** It holds files open under
  `build/`, which produces a corrupt DMG, and a corrupt DMG makes
  `notarytool submit` hang exactly like a dead connection — nothing reaches
  Apple, nothing is printed, and every network check comes back clean. A copy
  running from `/Applications` is allowed: it is the normal state of a menu-bar
  app and cannot hold `build/` open.
- **An existing DMG for this version is never overwritten** (`FORCE_REBUILD=1`
  if you mean it). That file may already be installed somewhere, and replacing
  its bytes under the same name makes "which build is that Mac running?"
  unanswerable.
- **Notarization runs under an outer 15-minute wall clock, three attempts.**
  `notarytool --timeout` covers the wait for Apple's verdict and not the upload,
  and the upload is the half that hangs, so that flag never fires.
- **A build carrying a Sentry DSN refuses to package without a symbol upload**
  (`ALLOW_NO_SYMBOLS=1` to override). Crash reports with no function names or
  line numbers are most of the way to no crash reports at all, and you find out
  months later on the one that mattered.

## Publishing a release

    Scripts/release.sh          build, notarize, staple, appcast, tag
    Scripts/publish.sh          put it on seedbed.dev

`release.sh` syncs **three** version-pinned surfaces before the gate runs, not
one: the appcast, `Casks/seedbed.rb` through `Scripts/sync-cask.sh`, and the
public site through `Scripts/sync-site.sh`, whose download links name the DMG by
file name. `check-release.sh` then re-checks all three, so a page or a cask
still pinned to the previous release cannot ship. The site is the surface a
stranger meets first and the one nobody here reads, which is exactly why it is
checked mechanically rather than remembered.

`publish.sh` deliberately cannot build. A script that can do both is one that can
publish something the release gate never saw, so this one re-runs the gate and
refuses if it does not pass.

The order is **DMG first, then appcast**, each landed atomically through a temp
path and `install` (the document root is root-owned). Two failure modes close
that way: a half-written DMG being served while the copy is still streaming, and
a run that dies between the two files leaving a feed that advertises a download
which 404s. In this order the worst interruption leaves the feed pointing at the
previous good release.

Then it verifies **what the server serves**, not what is on this disk: it
re-downloads the DMG and compares sha256, checks the served feed advertises this
build, and reports `cf-cache-status`, because Cloudflare sits in front and a
cached feed is the failure that looks exactly like a successful publish — the
origin is right and every client keeps being told it is current.

The document root is an nginx bind mount, so publishing is copying files in:
nothing is rebuilt and nothing restarts. `publish.sh` itself is not in this
repository — it names the host and path this particular site is served from, and
that is the only part of releasing which is nobody else's business. Set
`PUBLISH_HOST` and `PUBLISH_DIR` for your own.

The marketing site is deployed by a second script, kept out of this repository
for the same reason and landing in the same document root. It never touches the
DMG or the feed — those belong to `publish.sh`, and a site deploy that could
overwrite `appcast.xml` would roll the update channel backwards for every
installed copy. It refuses to publish a page whose download link does not
already answer 200, and it compares the sha256 of every asset **as served**
against the local file. That last check exists because a status code cannot tell
a current file from a cached one: the site served a superseded brand mark for
two days while the origin was correct, and every check then in place passed.

**The first Sparkle build cannot arrive through Sparkle.** 0.1.1 and earlier have
no updater in them, so any copy on those has to be replaced by hand once. The
same is true of a key rotation, for the same reason.

## Crash reports

Off. Two gates have to be open before anything leaves the Mac: the user turns
**Settings → General → Diagnostics → Send crash reports** on, *and* the build
carries a DSN. The tracked `Packaging/Info.plist` keeps `SentryDSN` empty;
`make-app.sh` writes the real one into the bundle's copy from
`Packaging/sentry-dsn.local` (gitignored, `*.local`) or `$SEEDBED_SENTRY_DSN`.
So every locally built copy is incapable of reporting regardless of the toggle,
and the toggle is disabled in Settings with a line saying why.

What is sent is the stack trace, the app version and the macOS version. What is
never sent is the library: prompts, renders and filled-in values are the whole
content of this app and none of it is captured. `sendDefaultPii` is off,
`beforeSend` drops user, server and request, the home directory is rewritten to
`~` (it carries the account name), and any run of 32 or more hex characters is
replaced — that is the shape of an MCP bearer token, and a leaked one can spend
LLM calls. `LibraryError.commandFailed` carries `promptlib` stderr, which can
quote a prompt, and is deliberately shown to the user and never captured.

`SEEDBED_TEST_SENTRY=1 build/Seedbed.app/Contents/MacOS/Seedbed` sends one event
and exits, so the wiring can be checked against the real project rather than
inferred from it having compiled.
