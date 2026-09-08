import AppKit
import SwiftUI

/// The client configuration a person copies into their MCP client.
///
/// Built here rather than inline in the view so its shape can be checked
/// without a window. The shape matters as much as the values: this snippet is
/// the only artifact the client is handed, and a malformed one fails in a way
/// that looks like a credential problem.
enum MCPClientSnippet {
    /// `"type": "http"` is required, not decoration. A sibling app's note on this is
    /// worth keeping: a client left to infer the transport can dial the URL and
    /// never send the `headers` block, which arrives at the far end as an
    /// unauthenticated request — and the symptom then points at the token
    /// rather than at the configuration.
    static func entry(name: String, url: String, token: String) -> String {
        """
        {
          "mcpServers": {
            "\(name)": {
              "type": "http",
              "url": "\(url)",
              "headers": {
                "Authorization": "Bearer \(token)"
              }
            }
          }
        }
        """
    }
}

/// How the outcome of a client-config write is shown: which symbol sits at the
/// head of the row, which tint it takes, and what colour the row is bordered in.
///
/// Lifted out of the view because it is the one part of the pane whose
/// correctness a person's eyes depend on, and a value can be checked without a
/// window. `ClaudeConfigInstaller.Report` exists because a write that reports
/// nothing is indistinguishable from one that failed; that only holds while the
/// two outcomes reach the screen looking different, and nothing used to check
/// that they did.
///
/// **The symbol, not the tint, is what carries the outcome.** A check in a
/// circle against a warning triangle is two different shapes, so the row still
/// says which happened to somebody who cannot tell the green from the amber, or
/// who is reading it in a greyscale capture. The tint is the fast signal on top
/// of that, never the only one — which is why the two must differ in both.
struct MCPReportRowStyle: Equatable {
    /// An SF Symbol name. Functional iconography, not brand art.
    let symbol: String
    let tint: Color
    let border: Color

    static let success = MCPReportRowStyle(
        symbol: "checkmark.circle.fill",
        tint: Tokens.positive,
        border: Tokens.Surface.hairline
    )

    /// Also the style of the pane's standing diagnostic rows, which are
    /// failures of the same kind: something is not as the person left it.
    static let failure = MCPReportRowStyle(
        symbol: "exclamationmark.triangle.fill",
        tint: Tokens.warning,
        border: Tokens.warning.opacity(0.4)
    )

    /// The row a report of this outcome is shown in.
    ///
    /// The pane hands this the report's own `succeeded` and keeps no branch of
    /// its own, so a failure cannot come to be dressed as a success by an edit
    /// to a view body that nothing can run.
    static func forOutcome(succeeded: Bool) -> MCPReportRowStyle {
        succeeded ? .success : .failure
    }
}

/// Turn the MCP server on, see its tokens, and copy a ready-to-paste client
/// configuration. The pane is also where the security model gets explained to
/// the person who has to decide about it, which is most of why it exists.
///
/// **THIS PANE RENDERS BOTH BEARER TOKENS IN CLEARTEXT**, and each one twice:
/// once in its own field and again inside the client-configuration snippet. That
/// is deliberate, because copying them is the whole point, and it is fine on
/// screen. It is not fine in a capture.
///
/// So: **do not screenshot this pane, and do not paste its contents anywhere.**
/// It happened once, on 2026-09-05, when an agent captured it to check the
/// layout against a spec and put both tokens into a transcript. The owner
/// accepted that exposure rather than rotating, on the grounds that
/// the server is loopback-only and the transcript never left the machine. That
/// reasoning holds only while both of those stay true.
///
/// Masking the tokens behind a reveal button was offered and not taken, so this
/// comment is the whole guard. If you are about to capture this window, capture
/// a different one.
struct MCPSettings: View {
    @ObservedObject var server: MCPServer
    /// Called when something needs the server rebound: the toggle, the port, or
    /// a regenerated token. Each of those is a restart, not a reload.
    var onChange: () -> Void
    /// Nil when hosted as a Settings pane; a window's close button is enough.
    var onDone: (() -> Void)?

    @AppStorage(AppController.mcpEnabledKey) private var enabled = false
    @AppStorage(AppController.mcpPortKey) private var port = Int(MCPConstants.defaultPort)

    /// Keychain-backed, not `@AppStorage`: these grant read access to the whole
    /// library and, for the full one, the ability to spend an LLM call. The
    /// preferences plist is readable by any process running as this user and is
    /// copied into every backup.
    @State private var token = ""
    @State private var readOnlyToken = ""
    @State private var confirmingRegenerate = false
    @State private var confirmingRegenerateReadOnly = false
    @State private var copied = ""
    /// What the last "Update my client config" press did, or nil before the
    /// first one. Shown in the pane rather than the footer, because it is
    /// several sentences and it needs to stay on screen while the person reads
    /// it. A write that reports nothing is indistinguishable from one that
    /// failed, which is the failure this whole button exists to end.
    @State private var configReport: ClaudeConfigInstaller.Report?

    /// How a UI test names the "Update my client config" button. A constant
    /// rather than a literal at the call site so a test and the pane cannot
    /// drift apart quietly: a renamed identifier that only a string comparison
    /// knows about turns into a test that no longer presses anything.
    static let updateConfigButtonIdentifier = "mcp.updateClientConfig"

    /// The environment variable a test harness points somewhere harmless with.
    ///
    /// Pressing "Update my client config" writes a real file: the MCP client
    /// configuration in the home folder of whoever is running the app. So a UI
    /// test that presses the button rewrites the tester's own configuration,
    /// and that is the whole reason the button went unpressed for as long as it
    /// did. Set this, and the press lands in a temp file instead; leave it
    /// unset, which the app always does, and the write goes exactly where it
    /// always went.
    static let clientConfigPathVariable = "SEEDBED_CLIENT_CONFIG_PATH"

    /// Where the button writes.
    ///
    /// This redirects the path and nothing else. The read-only token, the
    /// backup, the refusal to touch a file it cannot parse: all of that is
    /// `ClaudeConfigInstaller`'s and none of it is reachable from here. An
    /// empty value counts as unset, so an exported-but-blank variable cannot
    /// aim a write at the filesystem root.
    static func clientConfigPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let override = environment[clientConfigPathVariable] ?? ""
        return override.isEmpty ? ClaudeConfigInstaller.defaultPath : override
    }

    private var url: String { "http://127.0.0.1:\(port)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            SeedbedDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.regular) {
                    intro
                    serverSection
                    tokenSection
                    configSection
                }
                .padding(Tokens.Space.pane)
            }
            SeedbedDivider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            let tokens = MCPTokenStore.ensure()
            token = tokens.full
            readOnlyToken = tokens.readOnly
        }
        // Re-probed whenever the pane opens or the port field changes, because
        // whoever holds the old port can come and go while the app runs, and
        // the answer is only interesting at the moment somebody is looking.
        .task(id: port) {
            await server.refreshLegacyPortCheck(
                currentPort: UInt16(exactly: port) ?? MCPConstants.defaultPort
            )
        }
        .confirmationDialog("Regenerate the access token?",
                            isPresented: $confirmingRegenerate, titleVisibility: .visible) {
            Button("Regenerate", role: .destructive) {
                token = MCPServer.generateToken()
                MCPTokenStore.save(token)
                onChange()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every MCP client you have already set up stops working until you paste "
                 + "the new configuration into it.")
        }
        .confirmationDialog("Regenerate the read-only token?",
                            isPresented: $confirmingRegenerateReadOnly, titleVisibility: .visible) {
            Button("Regenerate", role: .destructive) {
                readOnlyToken = MCPServer.generateToken()
                MCPTokenStore.saveReadOnly(readOnlyToken)
                onChange()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Any client holding the read-only token stops working until you paste the "
                 + "new one into it. The full token is unaffected.")
        }
    }

    private var header: some View {
        HStack {
            Text("MCP Server").font(Tokens.FontScale.title)
            Spacer()
            if let onDone { Button("Done", action: onDone).keyboardShortcut(.defaultAction) }
        }
        .padding(.horizontal, Tokens.Space.pane).padding(.vertical, Tokens.Space.snug)
    }

    private var intro: some View {
        HStack(alignment: .top, spacing: Tokens.Space.tight) {
            Image(systemName: "info.circle.fill").foregroundStyle(Tokens.accent)
            VStack(alignment: .leading, spacing: Tokens.Space.row) {
                Text("Let an agent ask for a prompt")
                    .font(Tokens.FontScale.body.weight(.medium))
                Text("Claude Code, Cursor and Claude Desktop can search this library by "
                     + "description and read a prompt's tailored version, instead of you "
                     + "copying one out of the panel. The server binds to this Mac only, "
                     + "and every request has to carry the access token below. Both, not "
                     + "either.")
                    .font(Tokens.FontScale.small).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var serverSection: some View {
        section("Server") {
            Toggle("Run the MCP server", isOn: $enabled)
                .onChange(of: enabled) { _, _ in onChange() }
            HStack(spacing: Tokens.Space.tight) {
                Text("Port").font(Tokens.FontScale.body)
                TextField("Port", value: $port, format: .number.grouping(.never))
                    .frame(width: 80).multilineTextAlignment(.trailing)
                    .onSubmit { onChange() }
                Spacer()
            }
            statusRow
            diagnosticRows
            SettingsBullets([
                ("Run the MCP server",
                 "starts a small HTTP server on this Mac that an agent can call. It only runs "
                 + "while Seedbed is running."),
                ("Port",
                 "the number that server listens on. Change it only if something else on this "
                 + "Mac already uses it, and note the status line above reports the port "
                 + "actually bound, which is the one your client must dial."),
                ("After changing the port or a token",
                 "every client you already configured is now pointing at the old one and will "
                 + "fail to connect. Copy the configuration below again and replace the entry "
                 + "in that client. A stale entry reports an authentication error even when "
                 + "the real problem is the address, so when a refused client is looping "
                 + "Seedbed says so above rather than leaving you the bare error."),
                ("Why it is safe to leave on",
                 "it binds to loopback only, so nothing on your network can reach it, and "
                 + "every request must still carry a token. Both, not either. Ten wrong tokens "
                 + "in a row start a lockout that doubles from one minute to fifteen, while a "
                 + "correct token is always served, so a looping client cannot lock you out."),
            ])
        }
    }

    private var statusRow: some View {
        HStack(spacing: Tokens.Space.row6) {
            Circle()
                .fill(server.isRunning ? Tokens.positive : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            if server.isRunning {
                Text("Running at \(url)").font(Tokens.FontScale.small)
            } else if let error = server.lastError {
                Text(error).font(Tokens.FontScale.small).foregroundStyle(Tokens.danger)
            } else {
                Text("Not running").font(Tokens.FontScale.small)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// What the server learned from the requests it turned away, said here
    /// rather than left inside a 401 the person never sees in full.
    ///
    /// Both rows are absent when there is nothing to report, which is the
    /// normal state. A permanent line saying "no problems" would be one more
    /// thing to read past, and would make the warning easier to miss when it
    /// does appear.
    @ViewBuilder private var diagnosticRows: some View {
        if let alert = server.authAlert {
            warningRow(alert.title, alert.detail)
        }
        if server.legacyPortHeldByAnother {
            warningRow(
                "Another program is listening on port \(MCPConstants.legacyDefaultPort).",
                "Seedbed used that port before and now uses \(port). A client still aimed at "
                + "\(MCPConstants.legacyDefaultPort) is reaching that other program, not this "
                + "one, and it will report an authentication failure because the token it "
                + "sends means nothing there."
            )
        }
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.regular) {
            section("Access token") {
                secretRow(token)
                HStack(spacing: Tokens.Space.tight) {
                    Button("Copy token") { copy(token, as: "token") }.disabled(token.isEmpty)
                    Button("Regenerate") { confirmingRegenerate = true }
                    Spacer()
                }
                note("Anyone with this token and access to this Mac can read every prompt "
                     + "and can spend an LLM call by rebuilding one. Regenerating it "
                     + "invalidates the previous token immediately.")
            }
            section("Read-only token") {
                secretRow(readOnlyToken)
                HStack(spacing: Tokens.Space.tight) {
                    Button("Copy read-only token") { copy(readOnlyToken, as: "read-only token") }
                        .disabled(readOnlyToken.isEmpty)
                    Button("Regenerate") { confirmingRegenerateReadOnly = true }
                    Spacer()
                }
                note("A second token that can search and read but cannot rebuild anything, "
                     + "so it can never spend an LLM call. Give this one to any client that "
                     + "only needs to look a prompt up. A client holding it is not even "
                     + "offered the tool it cannot call.")
            }
        }
    }

    private var configSection: some View {
        section("Client configuration") {
            note("For a client on this Mac. There is no remote access and no tunnel: an "
                 + "agent that needs this library runs here.")
            Text(MCPClientSnippet.entry(name: "seedbed", url: url, token: token))
                .font(Tokens.FontScale.monoSmall)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Tokens.Space.tight)
                .background(RoundedRectangle(cornerRadius: Tokens.Radius.control)
                    .fill(Tokens.Surface.sunken))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control)
                    .stroke(Tokens.Surface.hairline, lineWidth: 0.5))
            HStack(spacing: Tokens.Space.tight) {
                Button("Copy configuration") {
                    copy(MCPClientSnippet.entry(name: "seedbed", url: url, token: token),
                         as: "configuration")
                }
                Button("Copy read-only configuration") {
                    copy(MCPClientSnippet.entry(name: "seedbed", url: url, token: readOnlyToken),
                         as: "read-only configuration")
                }
                // The read-only token, never the full one. A client this button
                // configures has not been trusted with anything: it was never
                // asked about, so it gets the token that cannot spend money.
                Button("Update my client config") {
                    configReport = ClaudeConfigInstaller.update(
                        url: url, token: readOnlyToken,
                        at: MCPSettings.clientConfigPath()
                    )
                }
                .disabled(readOnlyToken.isEmpty)
                // Named so a UI test can press this one by identity. Nothing in
                // the app reads it; it is here because the alternative is
                // pressing by position, and the two "Regenerate" buttons a few
                // points above rotate a bearer token and break every client
                // already configured. A miss there causes the exact failure
                // this button exists to end. SwiftUI publishes no usable label
                // for any button in this pane, so a script has nothing else to
                // aim at.
                .accessibilityIdentifier(MCPSettings.updateConfigButtonIdentifier)
                Spacer()
            }
            if let configReport {
                reportRow(MCPReportRowStyle.forOutcome(succeeded: configReport.succeeded),
                          configReport.title, configReport.detail)
            }
            note("\"Update my client config\" writes the read-only configuration straight into "
                 + "the Claude Code settings file in your home folder, replacing only the "
                 + "seedbed entry and leaving every other server in it alone. It saves the "
                 + "previous version beside it first, and it tells you which file it wrote. "
                 + "Nothing is written unless you press it, so a client you configured by "
                 + "hand stays exactly as you left it.")
        }
    }

    private var footer: some View {
        HStack {
            Text(copied.isEmpty ? " " : "Copied the \(copied).")
                .font(Tokens.FontScale.small).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, Tokens.Space.pane).padding(.vertical, Tokens.Space.tight)
    }

    // MARK: - Pieces

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.medium) {
            Text(title.uppercased())
                .font(Tokens.FontScale.tiny)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func secretRow(_ value: String) -> some View {
        Text(value.isEmpty ? "No token yet" : value)
            .font(Tokens.FontScale.monoSmall)
            .textSelection(.enabled)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Tokens.Space.row6)
            .background(RoundedRectangle(cornerRadius: Tokens.Radius.control)
                .fill(Tokens.Surface.sunken))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control)
                .stroke(Tokens.Surface.hairline, lineWidth: 0.5))
    }

    private func warningRow(_ title: String, _ detail: String) -> some View {
        reportRow(.failure, title, detail)
    }

    /// One row for both outcomes, told apart only by its style.
    ///
    /// A success is deliberately as prominent as a failure: the person needs to
    /// see which file was written and where the backup went, and a success
    /// reported in passing is one they will not read. What separates the two is
    /// `MCPReportRowStyle`, and nothing else in here reads the outcome, so the
    /// difference a person relies on cannot be changed from this function.
    private func reportRow(
        _ style: MCPReportRowStyle, _ title: String, _ detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.tight) {
            Image(systemName: style.symbol)
                .font(.system(size: Tokens.IconSize.compact))
                .foregroundStyle(style.tint)
            VStack(alignment: .leading, spacing: Tokens.Space.row) {
                Text(title).font(Tokens.FontScale.small.weight(.medium))
                Text(detail).font(Tokens.FontScale.small).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(Tokens.Space.row6)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.control)
            .fill(Tokens.Surface.sunken))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control)
            .stroke(style.border, lineWidth: 0.5))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Tokens.FontScale.small).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func copy(_ value: String, as label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = label
    }
}
