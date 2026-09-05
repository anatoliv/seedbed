import SwiftUI

/// One entry in the manual: a term and what it means.
///
/// The copy used to live as string literals inside `HelpPage` and `FAQPage`.
/// It moved here for two reasons. Search has to be able to rank a topic
/// and a topic is a title plus a body, which is exactly the shape
/// `promptlib.match` already scores. And a rule that is easy to state and hard
/// to show tends to stay unshown while the copy is spread across two view
/// bodies; with the entries in one list, an `example` that is missing is
/// visible at a glance.
struct ManualTopic: Identifiable {
    let page: InfoPage
    let section: String
    let term: String
    let detail: String
    /// A real artifact: a command you can run, a snippet you can paste, a
    /// message the app actually prints. Never an invented one.
    var example: String?
    /// Set when the term is a keyboard shortcut, which draws as a key cap
    /// rather than as a bold line of prose.
    var key: String?

    var id: String { "\(page.rawValue)|\(section)|\(term)" }

    /// What the search pass reads. The section title is in here because
    /// "keyboard" and "safety" are things people type.
    var searchText: String {
        [term, detail, example ?? "", section].joined(separator: "\n")
    }
}

/// A run of topics under one heading, on one page.
struct ManualSection: Identifiable {
    let page: InfoPage
    let title: String
    let topics: [ManualTopic]

    var id: String { "\(page.rawValue)|\(title)" }
}

/// The whole manual, Help and FAQ together.
///
/// Every example here is real. The word counts come from `wc -w` on the
/// rendered files, the commands were run before being quoted, and the error
/// strings are copied out of `MCPServer.swift` rather than paraphrased. An
/// invented example in a manual is worse than none, because the reader cannot
/// tell which kind they are looking at.
enum Manual {
    static let sections: [ManualSection] = help + faq

    static var topics: [ManualTopic] { sections.flatMap(\.topics) }

    static func sections(on page: InfoPage) -> [ManualSection] {
        sections.filter { $0.page == page }
    }

    // MARK: - Help

    static let help: [ManualSection] = [
        ManualSection(page: .help, title: "Keyboard", topics: keys),
        ManualSection(page: .help, title: "One prompt, start to finish", topics: walkthrough),
        ManualSection(page: .help, title: "Letting an agent ask for a prompt", topics: mcp),
        ManualSection(page: .help, title: "The words this app uses", topics: words),
        ManualSection(page: .help, title: "If something looks wrong", topics: symptoms),
    ]

    private static func key(_ cap: String, _ meaning: String) -> ManualTopic {
        ManualTopic(page: .help, section: "Keyboard", term: cap, detail: meaning,
                    example: nil, key: cap)
    }

    private static let keys: [ManualTopic] = [
        key("⌥⌘P", "Show or hide the panel, over any app, on any Space."),
        key("type", "Filter by title, prompt text, category or tag."),
        key("↑ ↓", "Move the selection."),
        key("⏎", "Copy, and paste into the app you came from."),
        key("⇧⏎", "Copy only. Nothing is pasted."),
        key("⌘1–9", "Copy that model's version. If it has never been built, it is built first."),
        key("⇧⌘1–9", "Copy that model's version without pasting."),
        key("⌥⌘1–9", "Rebuild just that one model. The other columns keep what they had."),
        key("⌘R", "Rebuild the selected prompt for every model it targets."),
        key("⇧⌘R", "Rebuild everything stale, pulling fresh vendor guidance first."),
        key("⌘D", "Pin the prompt to the top. Pins live in the seed file, so they travel with the library."),
        key("⌘E", "Edit the selected prompt in the library window."),
        key("⌘⌫", "Delete the selected prompt. You are shown what that destroys before it happens."),
        key("⌘S", "Cycle the sort: name, most used, last refreshed, recent."),
        key("⌘L", "Open the library window."),
        key("esc", "Close the panel. Clicking away closes it too."),
        key("hover", "The same actions, as icons on the row under the pointer, whatever is selected."),
    ]

    // MARK: The worked path
    //
    // Four of this app's words used to be defined in terms of each other, which
    // is fine for a glossary you already understand and useless for the person
    // reading it to find out. This section is one path through all four, using a
    // prompt that is really in the library, before the glossary defines any of
    // them separately.

    private static let walkthrough: [ManualTopic] = [
        ManualTopic(
            page: .help, section: "One prompt, start to finish",
            term: "Follow the prompt called Fix this bug and test",
            detail: """
                It is a real prompt in this library, and it uses every word the app has.

                You write the SEED. Here it is five words long: "fix this bug and test". \
                That is the whole thing you maintain, and it is the only text you ever edit.

                You choose TARGET MODELS for it. This one targets three: Claude Opus 5, \
                GPT-5.4 mini, and Llama 3.3 70B. A target is a prompting profile, not an \
                account. Adding one costs nothing and calls nothing.

                The ENHANCER writes the long versions. It is the model doing the writing, \
                and it is the only part of this app that spends anything. It reads each \
                target's published prompting guidance and expands your five words into a \
                prompt shaped for that model. From the same seed you get 233 words of \
                ordered prose for Opus 5 and 433 words of numbered steps for the Llama. \
                That difference is the whole reason to keep a library rather than a file \
                of snippets.

                Later you edit the seed. Every version built from it is now STALE, and \
                the library window puts an amber dot beside each one. Press ⌘R and they \
                are rebuilt from the new seed.

                One more word and you have all of them: CONTEXT, which says whether \
                you paste this prompt at an agent with your repo open or into a chat \
                window with a snippet. It changes what the enhancer writes, and it is the \
                one other thing that makes a render stale.
                """,
            example: """
                prompts/fix-bug-and-test.md      the seed you edit
                rendered/claude-opus-5/…         233 words, prose
                rendered/llama-3.3-70b/…         433 words, numbered steps
                """,
            key: nil),
    ]

    // MARK: MCP

    private static let mcp: [ManualTopic] = [
        ManualTopic(
            page: .help, section: "Letting an agent ask for a prompt",
            term: "Turning it on",
            detail: """
                Settings, then MCP. Switch it on and press Copy configuration, then paste \
                that into Claude Code, Cursor or Claude Desktop. The menu bar then carries \
                a line saying the server is serving agents, or a warning if it is switched \
                on and failed to start.

                The snippet is the only thing the client is handed, so its shape matters as \
                much as its values. "type": "http" is required rather than decoration: a \
                client left to guess the transport can dial the URL and never send the \
                headers, and the far end sees an unauthenticated request. The symptom then \
                looks like a bad token when the token was fine.
                """,
            example: """
                {
                  "mcpServers": {
                    "seedbed": {
                      "type": "http",
                      "url": "http://127.0.0.1:8787",
                      "headers": { "Authorization": "Bearer <token>" }
                    }
                  }
                }
                """,
            key: nil),
        ManualTopic(
            page: .help, section: "Letting an agent ask for a prompt",
            term: "What an agent can do",
            detail: """
                Five tools. find_prompt searches by description, get_prompt reads one by \
                id, list_prompts and list_models browse, and build_prompt renders a prompt \
                for a model. Clients that speak MCP prompts can also pull one straight \
                through prompts/get without calling a tool at all.
                """,
            example: "find_prompt · get_prompt · list_prompts · list_models · build_prompt",
            key: nil),
        ManualTopic(
            page: .help, section: "Letting an agent ask for a prompt",
            term: "Asking for a prompt by describing it",
            detail: """
                An agent never has to know what your prompts are called. It describes the \
                task, and the closest prompt comes back with the reason it was picked.

                Run the same thing yourself on the command line to see what an agent sees. \
                "decided by: semantic" means the plain text pass could not choose and the \
                enhancer was asked; "decided by: lexical" means it was free.
                """,
            example: """
                $ python3 -m promptlib match "something for reviewing a diff before I merge"
                decided by: semantic
                → review-my-diff  (0.22 on body)  Review my diff
                    It is exactly a pre-merge review of the user's changes.
                """,
            key: nil),
        ManualTopic(
            page: .help, section: "Letting an agent ask for a prompt",
            term: "The read-only token",
            detail: """
                Give it to any client you have not decided to fully trust. It can search \
                and read every prompt, and it cannot call build_prompt, so it can never \
                spend an LLM call.

                A client holding it is not even shown build_prompt when it asks what tools \
                exist, which saves it a turn discovering it cannot use one. If it calls the \
                tool anyway it is refused, and the refusal says which token it is holding \
                rather than just failing.
                """,
            example: """
                build_prompt rebuilds prompts, which spends an LLM call, and this
                client is using the read-only access token.
                """,
            key: nil),
        ManualTopic(
            page: .help, section: "Letting an agent ask for a prompt",
            term: "Reachable only from this Mac",
            detail: """
                Nothing on your network can connect to it. The listener binds to the \
                loopback interface, and there is no switch anywhere in the app that changes \
                that. On top of that, every single request has to carry the access token. \
                Both of those, not either one.
                """,
            example: nil, key: nil),
        ManualTopic(
            page: .help, section: "Letting an agent ask for a prompt",
            term: "Point the client at localhost or an IP, never at a domain name",
            detail: """
                That is the rule. Seedbed answers requests addressed to localhost, an IP \
                address, a .local name, or this Mac's own hostname, and refuses everything \
                else with "forbidden".

                The reason is worth knowing once. Without that rule, a web page you happen \
                to be visiting could point its own domain at your Mac and read the whole \
                library through your browser, because the browser would happily send the \
                request for it. That attack has a name, DNS rebinding, and checking the \
                address a request claims to be for is what stops it. A client of yours \
                configured with some other hostname is refused outright rather than half \
                working.

                Related, and a much more common mistake: the endpoint is the server root, \
                so the URL takes no path. A stray one returns "not found" and tells you to \
                drop it.
                """,
            example: """
                http://127.0.0.1:8787          answered
                http://localhost:8787          answered
                http://seedbed.example.com     forbidden
                http://127.0.0.1:8787/mcp      not found, drop the path
                """,
            key: nil),
        ManualTopic(
            page: .help, section: "Letting an agent ask for a prompt",
            term: "Wrong tokens get throttled",
            detail: """
                After ten failed attempts the server starts refusing further wrong-token \
                requests with a wait, doubling from one minute up to fifteen.

                A correct token is always served, even in the middle of a lockout, so \
                nothing can lock you out of your own library by guessing at it. If the \
                client being refused is one of yours, it is holding a token you \
                regenerated. Copy the configuration again and the next request clears it.
                """,
            example: """
                Too many requests with a wrong access token. Wait 60s, then retry
                with the token from Seedbed → MCP Server.
                """,
            key: nil),
    ]

    // MARK: The vocabulary

    private static let words: [ManualTopic] = [
        ManualTopic(
            page: .help, section: "The words this app uses",
            term: "Seed",
            detail: """
                The short prompt you maintain, and the only text you edit. "fix this bug \
                and test" is one.

                Only the seed's text decides whether a built version has gone out of date. \
                Renaming a prompt, pinning it, or moving it to another category never costs \
                a rebuild, which is deliberate.
                """,
            example: "fix this bug and test",
            key: nil),
        ManualTopic(
            page: .help, section: "The words this app uses",
            term: "Target model",
            detail: """
                A prompting profile: a name, and the documentation that says how to prompt \
                that model well. Targeting a model does not call that vendor and does not \
                need an account with them.

                Seedbed ships with four. A prompt lists the ones it is built for, and most \
                do not list all four.
                """,
            example: "claude-opus-5 · claude-sonnet-5 · gpt-5.4-mini · llama-3.3-70b",
            key: nil),
        ManualTopic(
            page: .help, section: "The words this app uses",
            term: "Enhancer",
            detail: """
                The model that writes the long versions, and the only thing here that \
                spends money. Settings, then Building.

                Out of the box it is the Claude Code CLI already on this machine, which \
                runs on the subscription you are already paying for, so nothing needs an \
                API key to work.
                """,
            example: nil, key: nil),
        ManualTopic(
            page: .help, section: "The words this app uses",
            term: "Stale",
            detail: """
                You edited the seed, so the version built for each model is now out of \
                date. The library window shows an amber dot next to it and the model chip \
                reads "stale". Press ⌘R to rebuild that prompt, or ⇧⌘R to rebuild \
                everything stale in one go.

                Only two things cause it: editing the seed, or the vendor's prompting \
                guidance changing under you. An orange dot on a chip is the neighbouring \
                case, which is a model this prompt targets but has never been built for.
                """,
            example: nil, key: nil),
        ManualTopic(
            page: .help, section: "The words this app uses",
            term: "Placeholder",
            detail: """
                A blank the prompt asks you to fill in when you copy it. Write it as \
                {{LIKE_THIS}} anywhere in the seed.

                The prompt "Fix a bug in a project" has two of them, and copying it opens a \
                small form with one field each. Each field remembers what you put there \
                before and offers those on a menu, so PROJECT is a one-click choice by the \
                second week. Leave a field empty and the {{PLACEHOLDER}} stays visible in \
                what you copy, rather than silently vanishing and leaving a sentence with a \
                hole in it.
                """,
            example: """
                seed:  fix {{BUG}} in {{PROJECT}} and add a regression test
                form:  BUG      [ crash on empty history      ▾ ]
                       PROJECT  [ Reference                  ▾ ]
                """,
            key: nil),
        ManualTopic(
            page: .help, section: "The words this app uses",
            term: "Context",
            detail: """
                Where you paste this prompt: an agent with your repo open, or a chat \
                window holding one snippet. It is the fifth word, and it earns its place \
                because getting it wrong measurably changes the answer you get.

                It is part of what makes a render stale, unlike a title or a category, \
                because a prompt written for an agent is genuinely wrong in a chat window \
                rather than merely differently worded. Change it and press ⌘R.
                """,
            example: nil, key: nil),
        ManualTopic(
            page: .help, section: "The words this app uses",
            term: "Category",
            detail: """
                Free-text grouping, and nothing more clever than that. Type anything. It \
                filters the library sidebar and is matched by typing in either window.
                """,
            example: nil, key: nil),
        ManualTopic(
            page: .help, section: "The words this app uses",
            term: "Adding a prompt",
            detail: """
                The + button at the bottom of the library window's list. It creates the \
                prompt, selects it, and puts you straight into Edit: a title, the one line \
                seed, a category, and which models to build it for. Save, then Rebuild.

                There is deliberately no ⌘N. In an accessory app with no main menu that \
                shortcut fires itself, and it did: a prompt appeared on its own while the \
                app sat idle.
                """,
            example: nil, key: nil),
    ]

    // MARK: Symptoms

    private static let symptoms: [ManualTopic] = [
        ManualTopic(
            page: .help, section: "If something looks wrong",
            term: "⏎ copies but does not paste",
            detail: """
                Accessibility permission has not been granted. Settings, then General, \
                shows the current state and the button that opens the right pane of System \
                Settings.

                Sending ⌘V to another application is exactly what that permission governs, \
                so there is no way around it. Until it is granted, Seedbed copies and tells \
                you why it did not paste, rather than appearing to do nothing.
                """,
            example: "System Settings → Privacy & Security → Accessibility → Seedbed",
            key: nil),
        ManualTopic(
            page: .help, section: "If something looks wrong",
            term: "The permission was granted and pasting stopped working anyway",
            detail: """
                The app was rebuilt with a different signature. macOS binds Accessibility \
                permission to the code signature, and an ad hoc signature changes on every \
                build, so the permission is revoked each time.

                Scripts/make-app.sh signs with a Developer ID when it finds one, which \
                keeps the signature stable across rebuilds. When it cannot find one it \
                falls back to ad hoc and prints a warning saying this will happen.
                """,
            example: nil, key: nil),
        ManualTopic(
            page: .help, section: "If something looks wrong",
            term: "Building with your ChatGPT subscription",
            detail: """
                Settings, then Building, then pick "ChatGPT sign-in" and press Sign in \
                with ChatGPT. Your browser opens, you consent, and it is done.

                No API key is involved. It uses the same sign-in the Codex CLI uses, so \
                the prompts are built against the ChatGPT plan you already pay for. The \
                tokens go into your login Keychain and never into a file, and the access \
                token is refreshed automatically when it expires.

                From a terminal it is the same thing without the window.
                """,
            example: """
                python3 -m promptlib enhancer login
                python3 -m promptlib enhancer whoami
                python3 -m promptlib enhancer logout
                """,
            key: nil),
        ManualTopic(
            page: .help, section: "If something looks wrong",
            term: "A build fails immediately",
            detail: """
                Settings, then Building, then press Test. It saves what you have entered \
                and then does a real round trip to the model, so a pass means the \
                configuration genuinely works rather than merely parsing.
                """,
            example: nil, key: nil),
        ManualTopic(
            page: .help, section: "If something looks wrong",
            term: "A model is missing from the picker",
            detail: """
                It is hidden, not gone. Settings, then Models, un-hides it. Hiding a model \
                never deletes it and never deletes anything built for it.
                """,
            example: nil, key: nil),
        ManualTopic(
            page: .help, section: "If something looks wrong",
            term: "Nothing loads at all",
            detail: """
                Seedbed runs the promptlib Python package out of the library folder, so it \
                needs Python 3.11 or newer and that folder present.

                One specific version of this is worth knowing about, because it looks like \
                a broken app rather than a missing interpreter. An app launched from Finder \
                inherits a minimal PATH, which on a Mac with Xcode installed can resolve \
                python3 to a 3.9 that has no tomllib. Everything then fails for you and \
                works in a terminal.
                """,
            example: "python3 -c 'import tomllib; print(\"ok\")'",
            key: nil),
        ManualTopic(
            page: .help, section: "If something looks wrong",
            term: "An MCP client cannot reach Seedbed",
            detail: """
                Check the menu bar first. It says whether the server is running, or warns \
                you that it is switched on and did not start.

                If it is running, the client is nearly always holding a regenerated token \
                or a URL with a path on the end. Copy the configuration again from \
                Settings, then MCP. Note also that the server lives inside this app, so \
                quitting Seedbed takes it down and the client sees a connection failure \
                rather than a message.
                """,
            example: """
                The bearer token this client sent isn't the one Seedbed is using.
                """,
            key: nil),
        ManualTopic(
            page: .help, section: "If something looks wrong",
            term: "The menu shows a count that looks out of date",
            detail: """
                On the very first open after launch it can, for about as long as it takes \
                to read it. The menu starts a reload when you open it and draws immediately \
                with what it already had, so the first click can show the startup numbers. \
                Close it and open it again.
                """,
            example: nil, key: nil),
    ]

    // MARK: - FAQ

    static let faq: [ManualSection] = [
        ManualSection(page: .faq, title: "Letting an agent use the library", topics: faqAgents),
        ManualSection(page: .faq, title: "Safety of the server", topics: faqSafety),
        ManualSection(page: .faq, title: "The library itself", topics: faqLibrary),
    ]

    private static let faqAgents: [ManualTopic] = [
        ManualTopic(
            page: .faq, section: "Letting an agent use the library",
            term: "What does the MCP server actually do?",
            detail: """
                It lets an agent fetch a prompt instead of you pasting one in. Claude Code, \
                Cursor and Claude Desktop can search this library by description, read a \
                prompt's tailored version for a given model, list the models, and rebuild a \
                prompt.

                The practical difference: you stop being the thing that carries prompts \
                from the library to the agent.
                """,
            example: nil, key: nil),
        ManualTopic(
            page: .faq, section: "Letting an agent use the library",
            term: "How do I point a client at it?",
            detail: """
                Settings, then MCP, then Copy configuration, then paste into the client's \
                config file. That is the whole procedure.

                What you get is a standard mcpServers block with the URL and the bearer \
                token already filled in. Nothing else needs setting up, and the URL takes \
                no path after the port.
                """,
            example: """
                {
                  "mcpServers": {
                    "seedbed": {
                      "type": "http",
                      "url": "http://127.0.0.1:8787",
                      "headers": { "Authorization": "Bearer <token>" }
                    }
                  }
                }
                """,
            key: nil),
        ManualTopic(
            page: .faq, section: "Letting an agent use the library",
            term: "What tools does an agent get?",
            detail: """
                Five. find_prompt searches by description, get_prompt reads one by id, \
                list_prompts and list_models browse, build_prompt generates or regenerates \
                a tailored version.

                Clients that support MCP prompts additionally see every prompt under \
                prompts/list and can pull one with prompts/get, without going through a \
                tool call at all.
                """,
            example: nil, key: nil),
        ManualTopic(
            page: .faq, section: "Letting an agent use the library",
            term: "An agent will not know what my prompts are called. Does that matter?",
            detail: """
                No. find_prompt takes a description in the agent's own words, so \
                "something for reviewing a diff before I merge" finds the prompt titled \
                "Review my diff".

                It tries a straight text match first, which is instant and free. Only when \
                that has no clear winner does it hand the candidates to your enhancer to \
                pick one and say why. You can watch it decide from the command line.
                """,
            example: """
                $ python3 -m promptlib match "something for reviewing a diff before I merge"
                decided by: semantic
                → review-my-diff  (0.22 on body)  Review my diff
                """,
            key: nil),
        ManualTopic(
            page: .faq, section: "Letting an agent use the library",
            term: "Does searching cost me anything?",
            detail: """
                Usually nothing at all. The text pass answers most asks on its own, in well \
                under a tenth of a second, with no model involved.

                The fallback runs only when that pass cannot choose between candidates, and \
                by default it goes through the Claude Code CLI, which uses a subscription \
                you already pay for rather than an API key. Rebuilding a prompt is the one \
                operation here that genuinely spends a call.
                """,
            example: nil, key: nil),
        ManualTopic(
            page: .faq, section: "Letting an agent use the library",
            term: "What does the read-only token stop?",
            detail: """
                Rebuilding, and only rebuilding. A client holding it can search and read \
                everything, and cannot call build_prompt, so it can never spend an LLM call.

                It is not even offered that tool in the list, which saves an agent a turn \
                discovering it cannot use it. Give it to anything you have not decided to \
                fully trust.
                """,
            example: nil, key: nil),
    ]

    private static let faqSafety: [ManualTopic] = [
        ManualTopic(
            page: .faq, section: "Safety of the server",
            term: "Who else can reach it?",
            detail: """
                Nobody. The listener binds to the loopback interface only, so a connection \
                from your network is refused before it begins, and there is no switch to \
                change that.

                On top of that, every request has to carry the access token. Both layers, \
                not either one.
                """,
            example: nil, key: nil),
        ManualTopic(
            page: .faq, section: "Safety of the server",
            term: "Where are the tokens kept?",
            detail: """
                In your login Keychain, never in the preferences file.

                A preferences file is readable by any process running as you, and it is \
                copied into every backup you take. That is the wrong home for something \
                that grants read access to a whole library.
                """,
            example: nil, key: nil),
        ManualTopic(
            page: .faq, section: "Safety of the server",
            term: "What happens if I regenerate a token?",
            detail: """
                Every client configured with the old one stops working immediately, and \
                gets an error saying so, until you paste the new configuration in. The pane \
                warns you before it does this.

                The two tokens are independent: regenerating the read-only one leaves the \
                full one untouched, and the other way round.
                """,
            example: nil, key: nil),
        ManualTopic(
            page: .faq, section: "Safety of the server",
            term: "Something is hammering the server with a wrong token. What happens?",
            detail: """
                It gets locked out and you do not. After ten failed attempts the server \
                starts refusing further wrong-token requests with a wait that doubles from \
                one minute up to fifteen.

                A correct token is served throughout, even in the middle of a lockout, so \
                nobody can lock you out of your own library by guessing at it.
                """,
            example: nil, key: nil),
        ManualTopic(
            page: .faq, section: "Safety of the server",
            term: "Why would a request be refused as forbidden?",
            detail: """
                Because the client connected to a domain name. Point it at localhost or an \
                IP address instead. Seedbed answers requests addressed to localhost, an IP \
                address, a .local name, or this Mac's own hostname, and refuses the rest.

                The reason that rule exists: without it, a web page you happen to be \
                visiting could point its own domain at your Mac and read the library \
                through your browser, since the browser would send the request on its \
                behalf. The attack is called DNS rebinding, and checking the address a \
                request claims to be for is what stops it.
                """,
            example: """
                This request's Host or Origin isn't one Seedbed answers to.
                Connect to the address shown in Seedbed → MCP Server.
                """,
            key: nil),
        ManualTopic(
            page: .faq, section: "Safety of the server",
            term: "My client says it cannot connect.",
            detail: """
                Open the menu bar menu first. It says whether the server is running, or \
                warns you that it is switched on and did not start.

                If it is running, the client is almost certainly using an old token or a \
                URL with a path on the end. Copy the configuration again from Settings, \
                then MCP. If the menu says nothing at all, Seedbed is not running: the \
                server lives inside the app and goes down with it.
                """,
            example: nil, key: nil),
    ]

    private static let faqLibrary: [ManualTopic] = [
        ManualTopic(
            page: .faq, section: "The library itself",
            term: "Where does everything live?",
            detail: """
                In the library folder, as plain markdown in a git repository. prompts/ \
                holds the seeds you maintain and rendered/ holds what each model made of \
                them.

                That is why history, sharing and backup come for free, and why you can read \
                a diff to see exactly how an expansion changed.
                """,
            example: """
                prompts/fix-bug-and-test.md            the seed
                rendered/claude-opus-5/…               its Opus version
                rendered/llama-3.3-70b/…               its Llama version
                models.toml                            the four target profiles
                """,
            key: nil),
        ManualTopic(
            page: .faq, section: "The library itself",
            term: "Do I need an API key?",
            detail: """
                Not by default. Prompts are built by the Claude Code CLI already on this \
                machine, which uses your existing subscription.

                Settings, then Building, if you would rather point it at an API, a local \
                server, or a different provider.
                """,
            example: nil, key: nil),
        ManualTopic(
            page: .faq, section: "The library itself",
            term: "What makes a prompt go stale?",
            detail: """
                Two things only: editing the seed, or the vendor's prompting guidance \
                moving under you.

                Renaming a prompt, pinning it, or filing it in a different category never \
                costs a rebuild, and that is deliberate. What you see is an amber dot in \
                the library for stale, and an orange dot on a chip for a model this prompt \
                targets but has never been built for.
                """,
            example: nil, key: nil),
        ManualTopic(
            page: .faq, section: "The library itself",
            term: "What are the prompts actually written for?",
            detail: """
                Whichever you tell it. Each prompt says where you paste it, and that \
                changes what gets built.

                Set it in the library window, under "Where you paste it". An agent with \
                the repo open gets a prompt that says to reproduce the failure and read \
                the surrounding code first. A chat window with a snippet gets one that \
                says the snippet is all there is, to work from the text alone, and never \
                to ask for files it cannot have.

                This is not a preference. It was measured: the same prompt built for an \
                agent and handed to a chat window with a bare snippet got the wrong \
                answer, twice, on two different models. Built for chat, it got it right. \
                Changing this setting makes that prompt's renders stale, because a prompt \
                written for one is genuinely wrong for the other.
                """,
            example: """
                agent:  "Reproduce the failure first. Find the relevant code
                         and tests, then run whatever demonstrates the bug."
                chat:   "The snippet below is the only material available to
                         you. Verify by reasoning, since you cannot run
                         anything."
                """,
            key: nil),
        ManualTopic(
            page: .faq, section: "The library itself",
            term: "Can I use it without the app?",
            detail: """
                Yes. The app is a front end over a Python package, and everything it does \
                has a command.
                """,
            example: """
                python3 -m promptlib list
                python3 -m promptlib copy fix-bug-and-test --model claude-opus-5
                python3 -m promptlib build --id fix-bug-and-test --model claude-opus-5
                python3 -m promptlib compare explain-this-code
                """,
            key: nil),
    ]
}
