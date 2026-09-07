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
                 + "the real problem is the address."),
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
                Spacer()
            }
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
