import SwiftUI

/// A page of the guide: one subject, explained in prose.
///
/// **Why this exists beside `Manual`.** The manual is a glossary — a term and a
/// sentence, forty of them, which is the right shape for "what does staleness
/// mean" and the wrong shape for "how do I get a prompt out of this thing". Put
/// Seedbed's Help follows Reference's browsable two-pane information architecture:
/// each subject gets a page, so a reader browses to what they want. Seedbed once
/// offered five pages, one of which was a table of key caps.
///
/// A guide page is what the sidebar lists. The glossary stays, because a
/// definition someone can scan is worth having and search reads both.
struct GuidePage: Identifiable {
    let id: String
    let category: String
    let title: String
    /// Markdown: paragraphs, `**bold**`, `- bullets`, and `    indented code`.
    let body: String

    var searchText: String { [title, category, body].joined(separator: "\n") }
}

enum Guide {
    /// The sidebar's groups, in reading order: what the app is, then the two
    /// surfaces you work in, then the things that make a prompt, then the ways
    /// the library reaches other software, then keeping it, then what to do
    /// when something looks wrong.
    static let categories: [(name: String, symbol: String)] = [
        ("Getting started", "sparkles"),
        ("The panel", "rectangle.stack"),
        ("The library window", "square.grid.2x2"),
        ("Models", "cpu"),
        ("Building a prompt", "wand.and.stars"),
        ("Placeholders", "curlybraces"),
        ("For agents", "network"),
        ("Keeping the library", "externaldrive"),
        ("If something looks wrong", "wrench.and.screwdriver"),
    ]

    static func symbol(for category: String) -> String {
        categories.first { $0.name == category }?.symbol ?? "questionmark.circle"
    }

    static func pages(in category: String) -> [GuidePage] {
        pages.filter { $0.category == category }
    }

    static let pages: [GuidePage] = gettingStarted + panel + libraryWindow
        + models + building + placeholders + agents + keeping + trouble
}

/// Prose, rendered.
///
/// A deliberately small subset: paragraphs, `**bold**` inline, `- ` bullets and
/// four-space indented code. Enough for a manual and nothing more, because the
/// alternative is a dependency that renders everything and has opinions about
/// all of it.
struct GuideMarkdown: View {
    @Environment(\.textScale) private var scale
    private let blocks: [Block]

    private enum Block: Identifiable {
        case paragraph(String)
        case bullets([String])
        case code(String)
        var id: String {
            switch self {
            case .paragraph(let t): return "p:" + t.prefix(40)
            case .bullets(let b):   return "b:" + (b.first ?? "").prefix(40)
            case .code(let t):      return "c:" + t.prefix(40)
            }
        }
    }

    init(_ text: String) {
        var out: [Block] = []
        var bullets: [String] = []
        var code: [String] = []
        func flush() {
            if !bullets.isEmpty { out.append(.bullets(bullets)); bullets = [] }
            if !code.isEmpty { out.append(.code(code.joined(separator: "\n"))); code = [] }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("    ") && !trimmed.isEmpty {
                if !bullets.isEmpty { flush() }
                code.append(String(raw.dropFirst(4)))
            } else if trimmed.hasPrefix("- ") {
                if !code.isEmpty { flush() }
                bullets.append(String(trimmed.dropFirst(2)))
            } else if trimmed.isEmpty {
                flush()
            } else {
                flush()
                out.append(.paragraph(trimmed))
            }
        }
        flush()
        blocks = out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.element) {
            ForEach(blocks) { block in
                switch block {
                case .paragraph(let text):
                    styled(text)
                case .bullets(let items):
                    VStack(alignment: .leading, spacing: Tokens.Space.tight) {
                        ForEach(items, id: \.self) { item in
                            HStack(alignment: .top, spacing: Tokens.Space.tight) {
                                Text("•").font(scale.body)
                                    .foregroundStyle(.secondary)
                                styled(item)
                            }
                        }
                    }
                case .code(let text):
                    ExampleBlock(text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `**bold**` and `` `code` `` come free from AttributedString; anything it
    /// cannot parse falls back to the literal text rather than disappearing.
    private func styled(_ text: String) -> some View {
        Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
            .font(scale.body)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Getting started

extension Guide {
    fileprivate static let gettingStarted: [GuidePage] = [
        GuidePage(id: "what-it-is", category: "Getting started", title: "What Seedbed is",
                  body: """
        You keep one short line. Seedbed keeps the long version for every model you use.

        A **seed** is the line you maintain, something like `fix this bug and test`. That is all you ever edit. For each model you target, Seedbed reads that model's own prompting guidance and expands your seed into a prompt shaped for it. The result is a **render**, and it is stored on disk so copying one later is a file read rather than a model call.

        The same seed becomes flowing prose for a model that needs little scaffolding, and numbered steps with a stated output format for one that needs a lot. That difference is the whole point of the tool.

        Nothing about the seed changes when a render is rebuilt. The seed is yours; the renders are generated, and you can throw them away.
        """),
        GuidePage(id: "first-prompt", category: "Getting started", title: "Your first prompt",
                  body: """
        Press **⌥⌘P** anywhere. The panel opens over whatever you were working in.

        Type a few letters to filter. The list matches on title, prompt text, category and tag, so `bug` finds *Fix this bug and test* whether or not you remember its name.

        Press **⏎**. The prompt for your usual model goes on the clipboard and is pasted straight into the app you came from. Hold **⇧** to copy without pasting.

        To pick a different model, press **⌘1** through **⌘9**. The number is the column position you see on the row. If that model has never been built for this prompt, Seedbed builds it first and then copies it, which takes about a minute.

        That is the whole loop. Everything else in this guide is detail.
        """),
        GuidePage(id: "where-library-lives", category: "Getting started", title: "Where your library lives",
                  body: """
        Seedbed is a front end. The prompts, the renders and the code that makes them live in a git checkout, and the app runs that code rather than reimplementing it.

        By default it looks in `~/Projects/seedbed`. To point it somewhere else, open the menu bar icon, then **Settings**, then **General**, then **Choose**.

        A folder is only a library if it contains the `promptlib` package. Picking a folder of loose markdown files is refused, with the reason, rather than failing three actions later with an import error.

        The checkout also needs **Python 3.11 or newer**, because the prompt files are TOML fronted and `tomllib` arrived in 3.11. Seedbed probes the usual locations and picks the first interpreter that works, so it does not matter whether Python is on your PATH.
        """),
        GuidePage(id: "menu-bar", category: "Getting started", title: "The menu bar icon",
                  body: """
        Seedbed has no Dock tile. The menu bar icon is where it lives, and the menu opens with the state worth knowing before anything you can click.

        What you will find there:

        - A **count** of prompts and models in the library you are pointed at.
        - **Builds with**, naming the enhancer that expands your seeds and whether it needs a key.
        - A warning when **renders are stale**, meaning a seed or its guidance changed after the render was made.
        - A warning when the **MCP server** is switched on and not actually listening.
        - A warning when **Accessibility permission** has not been granted, which is what ⏎ needs in order to paste.

        Below that: show the panel, open the library window, rebuild what is stale, settings, this guide, check for updates, and quit.
        """),
    ]

    // MARK: - The panel

    fileprivate static let panel: [GuidePage] = [
        GuidePage(id: "panel-open", category: "The panel", title: "Opening and filtering",
                  body: """
        **⌥⌘P** shows the panel and presses again to hide it. It floats over full screen apps and follows you between Spaces, because the moment you want a prompt is a moment you are already inside something else.

        Typing filters immediately. There is no search button and no delay. The match runs over the title, the body of the seed, the category and every tag, so you can find a prompt by what it does rather than by what you called it.

        **↑** and **↓** move the selection. **esc** closes the panel, and so does clicking anywhere outside it.

        The panel remembers nothing between openings on purpose. It opens empty and ready to type, which is faster than opening on whatever you did last.
        """),
        GuidePage(id: "panel-copy", category: "The panel", title: "Copying and pasting",
                  body: """
        **⏎** copies the prompt and pastes it into the app that was frontmost when you summoned the panel. **⇧⏎** copies without pasting.

        Pasting needs the **Accessibility** permission, because sending ⌘V to another application is exactly what that permission governs. macOS asks the first time. Until it is granted, Seedbed copies and tells you why it did not paste, rather than appearing to do nothing.

        The target app is captured **before** the panel opens, because opening the panel is itself what takes focus away from it.

        Which model you get with a bare ⏎ is the one you use most for that prompt, falling back to the first one that has been built. With seven models on a row, the first one is rarely the one you want.
        """),
        GuidePage(id: "panel-models", category: "The panel", title: "Model columns",
                  body: """
        Each row shows a small chip per model the prompt targets, with a coloured dot:

        - **Moss** means the render is current.
        - **Amber** means it is stale: the seed, the vendor guidance, or the context changed after it was built.
        - **Grey** means it has never been built.

        **⌘1** through **⌘9** copy the version for the chip in that position, counting only the models you have chosen to show. **⇧⌘1–9** copies without pasting.

        Asking for a model that has never been built builds it first. That costs one model call and about a minute, and then it is on disk for good.

        To work with fewer models, use **Models shown** in the library window's header. It is a view filter and never a delete: hidden models keep their renders.
        """),
        GuidePage(id: "panel-rebuild", category: "The panel", title: "Rebuilding",
                  body: """
        A render goes stale when the thing it was made from changes. Seedbed decides that by hashing the seed and the guidance rather than by looking at dates, so editing a seed and changing it back leaves everything current.

        - **⌥⌘1–9** rebuilds just that one model. The other columns keep what they had.
        - **⌘R** rebuilds the selected prompt for every model it targets.
        - **⇧⌘R** rebuilds everything stale across the whole library, pulling fresh vendor guidance first.

        Each rebuild is a model call, so the last of those is the expensive one. It reports progress and can be left running.

        If the guidance for a model cannot be fetched, the build refuses rather than quietly rebuilding on worse input than the render it would replace.
        """),
        GuidePage(id: "panel-pins", category: "The panel", title: "Pins, sort and row actions",
                  body: """
        **⌘D** pins the selected prompt to the top of the list. Pins are stored in the seed file itself, so they travel with the library to your other machines rather than living in one Mac's preferences.

        **⌘S** cycles the sort: by name, most used, last refreshed, and most recent.

        **Hovering** a row reveals the same actions as icons on the row itself: copy, paste, rebuild, edit, pin and delete. They act on the row under the pointer, not on whatever happens to be selected, which is the only behaviour that makes sense when your hand is already on the mouse.

        **⌘E** opens the selected prompt in the library window. **⌘⌫** deletes it, after showing you how many renders that destroys, because each one cost a model call.
        """),
    ]
}

// MARK: - The library window

extension Guide {
    fileprivate static let libraryWindow: [GuidePage] = [
        GuidePage(id: "lib-browse", category: "The library window", title: "Browsing the library",
                  body: """
        **⌘L**, or **Library** in the menu bar menu. This is where you work on prompts rather than reach for one.

        The sidebar lists every seed with its category, how many models it targets and how often you have copied it. Pinned prompts sit at the top. The search field above the list narrows it the same way the panel does.

        Selecting a seed opens it in the editor beside the list. Nothing is saved until you say so, and the header tells you when there are unsaved changes rather than saving under you.

        The header also carries **Models shown**, which decides how many columns the compare view draws and how ⌘1–9 are numbered everywhere. It is a view filter, never a delete.
        """),
        GuidePage(id: "lib-edit", category: "The library window", title: "Editing a seed",
                  body: """
        A seed is a title, a short body, and the list of models it targets. Everything else on the page is generated from those.

        - The **body** is the line you maintain. Keep it short. It is the input to every render, and a seed that already reads like a full prompt gives the enhancer nothing to do.
        - **Targets** decide which models get built. Adding one does not build it; the render appears as never built until something asks for it.
        - **Category** and **tags** are for finding things later. Both are matched by search in both windows.
        - **Context** says where the prompt gets pasted, agent or chat. It changes what the enhancer is asked to write, so it is part of staleness.

        Saving writes the markdown file in `prompts/` directly. There is no database.
        """),
        GuidePage(id: "lib-compare", category: "The library window", title: "Comparing models",
                  body: """
        The compare view puts each model's render in its own column, side by side, so you can see what the same seed became for each one.

        This is the fastest way to answer whether a model needs the scaffolding you are paying for. One column being twice the length of another is not a defect; it is the difference in what those two models need in order to do the same job.

        **How these differ** asks the enhancer to summarise the differences in a sentence or two, and stores that summary in `comparisons/`. It goes stale the same way a render does, and says so.

        The columns are the models you have chosen to show. Hiding one here does not touch its renders.
        """),
    ]

    // MARK: - Models

    fileprivate static let models: [GuidePage] = [
        GuidePage(id: "models-registry", category: "Models", title: "The model registry",
                  body: """
        `models.toml` at the root of the library is the list of models Seedbed knows about. Each entry carries a display name, the family it belongs to, the URLs of its prompting guidance, and a note.

        The **note** is guidance you write yourself, and it is always part of what the enhancer reads. For a local model with no published documentation, the note is the entire guidance. Changing a note restages every render for that model, because you have changed the instructions they were built from.

        The file is plain TOML in the library, so it travels with the checkout and is reviewed in a diff like everything else.
        """),
        GuidePage(id: "models-add", category: "Models", title: "Adding or changing a model",
                  body: """
        Menu bar icon, then **Settings**, then **Models**. The pane edits `models.toml` and writes it back to the library you are pointed at, so changing the library folder while it is open retargets it rather than saving into the checkout you moved away from.

        What a new model needs:

        - An **id**, lowercase with hyphens, which is how renders are filed on disk under `rendered/<id>/`.
        - A **display name**, which is what the chips and columns show.
        - Zero or more **guidance URLs**. A model with none is legitimate: its note becomes its whole guidance.

        Removing a model leaves its renders on disk on purpose, so adding it back does not cost a rebuild.
        """),
        GuidePage(id: "models-guidance", category: "Models", title: "Vendor guidance",
                  body: """
        Before a render is built, Seedbed fetches the prompting guidance for that model, strips it to text and caches it under `.cache/guides/`. The cache is machine local and gitignored, so a stale copy on one Mac never travels to another.

        **Refresh guidance** re-pulls every source and rebuilds only what actually changed. Because staleness is a hash of the guidance rather than a date, a vendor reformatting a page without changing its substance does not cost you a library-wide rebuild.

        If a source cannot be read, the build refuses rather than rebuilding on partial guidance. A render made from worse input than the one it replaces is worse than no rebuild, and the failure is loud for that reason.

            python3 -m promptlib guides fetch
        """),
        GuidePage(id: "models-stale", category: "Models", title: "What staleness means",
                  body: """
        A render records three things about how it was made: a hash of the seed, a hash of the guidance, and the context it was written for. It is **current** when all three still match, and **stale** when any one of them does not.

        That is why editing a seed and changing it back leaves everything current, and why changing a model's note restages every render for that model.

        The menu bar menu counts what is stale. **⇧⌘R** rebuilds all of it, fetching fresh guidance first. On a large library that is a lot of model calls, so it reports progress and can be left alone.

        Stale is not broken. A stale render is the last good one, and it stays on the clipboard exactly as it is until you rebuild it.
        """),
    ]
}

// MARK: - Building a prompt

extension Guide {
    fileprivate static let building: [GuidePage] = [
        GuidePage(id: "build-enhancer", category: "Building a prompt", title: "The enhancer",
                  body: """
        The **enhancer** is the model that turns your seed into a render. It reads three things: your seed, the target model's guidance, and where the prompt will be pasted.

        Out of the box it is the **Claude Code CLI** already on this machine, which means no API key, no account setup and no separate spend. Seedbed shells out to it the same way you would from a terminal.

        The enhancer is not the model your prompt is for. You can expand a prompt for a local Llama using Claude as the enhancer, and that is the usual arrangement: a strong model writing careful instructions for a weaker one.

        Menu bar icon, then **Settings**, then **Building**.
        """),
        GuidePage(id: "build-presets", category: "Building a prompt", title: "Presets and keys",
                  body: """
        Three shapes of enhancer, and you can point at any endpoint that speaks one of them:

        - **Claude Code CLI**, the default. Uses the CLI on this machine. No key.
        - **Anthropic**, using the official SDK with an API key.
        - **OpenAI compatible**, which is any endpoint speaking that API, including one running on your own hardware.

        Keys live in the **login Keychain**, never in the library and never in a file in the checkout. That matters because the library is a git repository you push.

        A local endpoint is the reason the third option exists. If the enhancer runs on your own machine, expanding a seed costs nothing and leaves no trace anywhere else.
        """),
        GuidePage(id: "build-context", category: "Building a prompt", title: "Agent or chat",
                  body: """
        Every seed says where its prompt gets pasted, and it changes what the enhancer is asked to write.

        - **Agent** means the prompt lands in something that has your code: Claude Code, Cursor, an editor extension. A render for an agent can say "reproduce the failure first" and "read the surrounding code before changing anything", because the thing reading it can do those.
        - **Chat** means a bare chat window with no repository. The same instruction there makes the model hunt for code that is not present and decline to answer.

        This was measured rather than assumed. Given a bare snippet, an agent-shaped render searched for code that was not there and lost both fix tasks to the raw seed. Given the same bug inside a repository, it recovered.

        Context is part of staleness, so changing it restages that seed's renders.
        """),
        GuidePage(id: "build-cost", category: "Building a prompt", title: "What a build costs",
                  body: """
        One model call per seed per model, once. After that, copying a prompt is reading a file.

        That is the trade the whole design rests on: you pay at build time, in the background, rather than at the moment you want the prompt.

        The calls that cost the most are the ones you did not ask for one at a time. **⇧⌘R** rebuilds everything stale, which on a library of nine seeds and five models can be dozens of calls. It is the right thing to run after refreshing guidance, and the wrong thing to run absent-mindedly.

        Deleting a prompt shows you how many renders that destroys before it happens, for the same reason.
        """),
    ]

    // MARK: - Placeholders

    fileprivate static let placeholders: [GuidePage] = [
        GuidePage(id: "vars-write", category: "Placeholders", title: "Writing a placeholder",
                  body: """
        Put `{{SOMETHING}}` anywhere in a seed and Seedbed will ask for its value before the prompt reaches your clipboard.

        Use them for the part that changes every time and nothing else. A seed that reads `fix {{BUG}} in {{FILE}} and test` has turned a prompt you maintain into a form you fill in, which is slower than typing the sentence.

        The name is what you are asked for, so name it as a question you can answer. `{{BUG}}` reads better in the sheet than `{{X}}`.

        Placeholders survive into every render, because the enhancer is told to keep them. A render that quietly resolved one would give you a prompt about someone else's bug.
        """),
        GuidePage(id: "vars-fill", category: "Placeholders", title: "Filling one in",
                  body: """
        Copying a prompt that has placeholders opens a small sheet, one field per placeholder, in the order they appear.

        Values you have used before are on a menu beside each field, most recent first, so the second time you reach for the same prompt is faster than the first. Those are remembered per placeholder name rather than per prompt, so `{{FILE}}` in one seed offers what you typed for `{{FILE}}` in another.

        The remembered values live in `.variables.json` at the root of the library, which is **gitignored**. They are yours and they stay on this machine.

        Leaving a field empty leaves the placeholder in place, which is occasionally what you want when you are about to edit the prompt anyway.
        """),
    ]
}

// MARK: - For agents

extension Guide {
    fileprivate static let agents: [GuidePage] = [
        GuidePage(id: "mcp-what", category: "For agents", title: "Letting an agent ask",
                  body: """
        Seedbed can run an **MCP server**, so Claude Code, Cursor or Claude Desktop fetches the prompt it needs instead of you copying one across.

        The interesting tool is **find_prompt**, which takes a description rather than a name. An agent asking for "something for reviewing a diff before I merge" gets the prompt titled *Review my diff*. A text match answers most asks on its own in well under a tenth of a second, and only when it cannot choose does the ask go to the enhancer to be settled.

        The same thing works from the command line:

            python3 -m promptlib match "reviewing a diff before I merge"
        """),
        GuidePage(id: "mcp-on", category: "For agents", title: "Turning it on",
                  body: """
        Menu bar icon, then **Settings**, then **MCP**. Switch it on, press **Copy configuration**, and paste that into your client.

        The menu bar menu shows whether the server is actually listening, not merely whether the switch is on. A failed bind is otherwise silent, and a switch that says on over a server that never started is the worst of both.

        The port is yours to change. The default is 8787 and it binds to the loopback interface only.

        The configuration it copies is the whole block your client expects, including the token, so there is nothing to assemble by hand.
        """),
        GuidePage(id: "mcp-tools", category: "For agents", title: "What an agent can do",
                  body: """
        Five tools:

        - **find_prompt**, a description in, the right prompt out.
        - **get_prompt**, a named prompt for a named model.
        - **list_prompts** and **list_models**, for an agent that wants to choose for itself.
        - **build_prompt**, which renders a prompt that has never been built. This is the only one that spends a model call.

        Every prompt is also exposed through MCP's own `prompts/list` and `prompts/get`, so a client that knows nothing about these five tools still sees the library.

        Reading is cheap and building is not, which is why the two are separable. See the next page.
        """),
        GuidePage(id: "mcp-tokens", category: "For agents", title: "Two tokens, two levels of trust",
                  body: """
        Two things protect the endpoint, and both are required rather than either being enough.

        The listener binds to **loopback**, so nothing on your network can reach it. And every request must carry a **bearer token**.

        There are two tokens. The full one can call everything. The **read only** token can look prompts up but can never call `build_prompt`, so a client you have not decided to trust cannot spend a model call on your account.

        Both live in the **login Keychain**. They were once in a preferences file in cleartext, readable by any process running as you, which is the reason the Keychain is not optional here.

        The settings pane shows both and warns, in the pane itself, that it is rendering them in cleartext.
        """),
    ]

    // MARK: - Keeping the library

    fileprivate static let keeping: [GuidePage] = [
        GuidePage(id: "keep-git", category: "Keeping the library", title: "Why files and git",
                  body: """
        Prompts change slowly and need to exist on more than one computer. Git gives sharing, history, backup and conflict resolution with no server, and it works away from your own network.

        Renders are committed too, which means `git diff` shows how an expansion changed when the guidance moved. You review a diff rather than trusting a black box.

        What is deliberately **not** committed: your copy counts, the values you have typed into placeholders, the guidance cache, and any API key. Those are machine local, and a stale one travelling to another Mac would be worse than not having it.

            models.toml               which guidance belongs to which model
            prompts/<id>.md           the seeds you maintain
            rendered/<model>/<id>.md  generated expansions, with provenance
        """),
        GuidePage(id: "keep-second-mac", category: "Keeping the library", title: "On a second Mac",
                  body: """
        Two pieces, because Seedbed is a front end and the library is separate from it.

        Install the app from the disk image: drag it to Applications and it launches. That Mac needs no Swift toolchain and no build.

        Then give it the library: clone the repository wherever you keep code. Seedbed looks in `~/Projects/seedbed` unless Settings says otherwise. That Mac also needs **Python 3.11 or newer**.

        Until both halves are there the app opens and says which one is missing rather than showing an empty list. An empty library and an unreadable one look identical otherwise, and only one of them is your fault.
        """),
        GuidePage(id: "keep-updates", category: "Keeping the library", title: "Check for Updates",
                  body: """
        It means two different things, and Seedbed tells them apart rather than giving you advice you cannot follow.

        A copy **built from the checkout** is told what commits it is behind and to pull and rebuild. Offering it a shipped release would replace the build you are working on.

        A copy **installed from a release** checks the update feed and offers to install a newer version.

        Either way, updating the app does not update your library. The prompts are a git checkout, so `git pull` is the other half, and no updater can do it for you.
        """),
        GuidePage(id: "keep-crash", category: "Keeping the library", title: "Crash reports",
                  body: """
        Off, and off twice over.

        Two things must both be true before anything leaves this Mac: you turn it on in **Settings**, then **General**, then **Diagnostics**, and the build has to carry a reporting address. No copy built on the machine it runs on has one, so a self built Seedbed cannot report whatever the switch says.

        What is sent is the stack trace and the versions. What is never sent is your library: prompts, renders and the values you have filled in are the entire content of this app and none of it is captured. Your home folder path is replaced with a tilde before anything is sent, and anything shaped like an access token is redacted.

        At most twenty events per launch, so a crash loop cannot turn into a flood.
        """),
    ]
}

// MARK: - If something looks wrong

extension Guide {
    fileprivate static let trouble: [GuidePage] = [
        GuidePage(id: "trouble-empty", category: "If something looks wrong", title: "It says 0 prompts",
                  body: """
        A library that cannot be **read** counts as zero of everything, which looks exactly like an empty one. The menu bar menu says which, on the line under the count.

        The two causes, in the order they happen:

        - **No Python 3.11 or newer.** The library is TOML fronted and needs `tomllib`. Install one with `brew install python`. Seedbed probes the usual locations, so it does not need to be on your PATH.
        - **The folder is not a library.** It has to be a checkout containing the `promptlib` package, not a folder of markdown files. Settings, General, Choose.

        To name an interpreter explicitly:

            defaults write net.amnesia.seedbed PythonPath /path/to/python3
        """),
        GuidePage(id: "trouble-paste", category: "If something looks wrong", title: "⏎ copies but does not paste",
                  body: """
        Pasting into another application needs the **Accessibility** permission, because sending ⌘V to an app you are not in is exactly what that permission governs.

        Settings, General, and the warning there opens the right pane of System Settings directly.

        One thing worth knowing: macOS ties that permission to the app's code signature. A copy signed ad hoc gets a new signature on every build, so the permission is revoked each time you rebuild. A copy signed with a Developer ID keeps a stable identity and the permission survives, which is why the build script prefers one.

        Until it is granted, Seedbed copies and says why it did not paste, rather than appearing to do nothing.
        """),
        GuidePage(id: "trouble-hotkey", category: "If something looks wrong", title: "⌥⌘P does nothing",
                  body: """
        Another application has claimed it. macOS gives a global hot key to whoever asks first, and does not report a conflict to the loser.

        Seedbed notices that it failed to register and says so in the menu bar icon's tooltip rather than looking broken. **Show Prompts** in the menu opens the panel regardless.

        The usual culprits are screenshot tools, window managers and clipboard utilities. Quitting the other app and relaunching Seedbed gets the key back.
        """),
        GuidePage(id: "trouble-guidance", category: "If something looks wrong", title: "Guidance unavailable",
                  body: """
        A vendor moved or removed the page a model's guidance is fetched from.

        Seedbed does not quietly build on what is left. The blob carries the failure, the build refuses, and `guides` exits non-zero, because a rebuild on partial guidance produces a render worse than the one it replaces and nothing on screen would say so.

        Check every source at once:

            python3 -m promptlib guides fetch

        Then either fix the URL in Settings, Models, or drop it and let that model's note carry the guidance on its own. A model with no external sources is a legitimate entry, not a broken one.
        """),
        GuidePage(id: "trouble-mcp", category: "If something looks wrong", title: "MCP is on but not running",
                  body: """
        The switch is a preference; the line in the menu is the truth. That wording exists because a failed bind is otherwise silent, and a client that cannot connect gives you no reason.

        Almost always the port is taken. Change it in Settings, MCP, and copy the configuration again, because the port is in it.

        If a client connects and every call is refused, the token in its configuration is not the token in the Keychain. Copying the configuration afresh fixes that, and is faster than comparing two long hex strings by eye.

        A client using the **read only** token that tries to build gets refused on purpose. That is the token doing its job, not a fault.
        """),
    ]
}
