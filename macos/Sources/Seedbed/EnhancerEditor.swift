import SwiftUI

/// Configuring the model that *builds* prompts.
///
/// Not the same thing as a target model. A target is a profile that shapes what
/// gets written; the enhancer is the model actually called to do the writing,
/// and it is the only place in this app that spends money or needs a key.
///
/// Uses the shared sibling-app Settings → AI structure: provider presets, auth modes,
/// endpoint + model, a Keychain-held key, and a fallback tried once when the
/// primary fails retryably.
struct EnhancerConfigData: Decodable {
    let auth: String
    let endpoint: String
    let model: String
    let preset: String
    let timeout: Int
    let fallbackEndpoint: String
    let fallbackModel: String
    let hasKey: Bool
    let hasFallbackKey: Bool
    let summary: String
    let problems: [String]
    let presets: [PresetData]
    let authModes: [String]

    struct PresetData: Decodable, Identifiable, Hashable {
        let id: String
        let name: String
        let endpoint: String
        let model: String
        let auth: String
    }

    enum CodingKeys: String, CodingKey {
        case auth, endpoint, model, preset, timeout, summary, problems, presets
        case fallbackEndpoint = "fallback_endpoint"
        case fallbackModel = "fallback_model"
        case hasKey = "has_key"
        case hasFallbackKey = "has_fallback_key"
        case authModes = "auth_modes"
    }
}

@MainActor
final class EnhancerEditorModel: ObservableObject {
    @Published var data: EnhancerConfigData?
    @Published var status = ""
    @Published var statusIsError = false
    @Published var busy = false

    @Published var auth = "cli"
    @Published var endpoint = ""
    @Published var model = ""
    @Published var key = ""
    @Published var timeout = 300
    @Published var fallbackEndpoint = ""
    @Published var fallbackModel = ""
    @Published var fallbackKey = ""
    /// "signed in as …", or nil. Never holds a token.
    @Published var codexAccount: String?

    /// `var`, not `let`: the library folder can change under an open Settings
    /// window, and this client decides which checkout `setEnhancer` WRITES to.
    /// Frozen, it silently saved into the checkout you moved away from.
    var client: LibraryClient

    init(client: LibraryClient) {
        self.client = client
        load()
    }

    /// Point at a different library and re-read its configuration.
    ///
    /// Reloading rather than keeping the form is right here, and it is the
    /// opposite of `ModelsEditorModel.adopt`: a half-typed model is your work
    /// and must survive, but an endpoint typed against library A is not a draft
    /// you want silently saved into library B.
    func retarget(to client: LibraryClient) {
        guard client.root != self.client.root else { return }
        self.client = client
        load()
    }

    /// True when the chosen mode talks to an HTTP endpoint at all. The CLI and
    /// SDK backends have no endpoint, model field or key.
    var needsEndpoint: Bool { ["api_key", "azure_api_key", "chatgpt_oauth"].contains(auth) }
    var needsKey: Bool { ["api_key", "azure_api_key"].contains(auth) }

    func load() {
        Task.detached { [client] in
            let loaded: EnhancerConfigData
            do {
                loaded = try client.enhancerConfig()
            } catch {
                // Say so rather than returning. This used to be
                // `guard let ... else { return }`, so a library the app could
                // not read left the pane showing the PREVIOUS library's
                // settings with no indication anything had failed — which is
                // exactly the shape of the retargeting bug. Found by
                // pointing the retarget hook at a folder with no promptlib.
                await MainActor.run {
                    self.status = "could not read the enhancer config in "
                        + "\(client.root.lastPathComponent): "
                        + error.localizedDescription
                    self.statusIsError = true
                }
                return
            }
            await MainActor.run {
                self.data = loaded
                self.auth = loaded.auth
                self.endpoint = loaded.endpoint
                self.model = loaded.model
                self.timeout = loaded.timeout
                self.fallbackEndpoint = loaded.fallbackEndpoint
                self.fallbackModel = loaded.fallbackModel
                self.key = ""            // never round-tripped; blank means "leave it"
                self.fallbackKey = ""
                self.status = loaded.problems.first ?? loaded.summary
                self.statusIsError = !loaded.problems.isEmpty
            }
        }
        refreshCodexAccount()
    }

    func refreshCodexAccount() {
        Task.detached { [client] in
            let who = client.codexWhoami()
            await MainActor.run { self.codexAccount = who }
        }
    }

    /// Sign in, which opens a browser and can take as long as the person does.
    func codexLogin() {
        guard !busy else { return }
        busy = true
        status = "Opening your browser. Finish signing in there…"
        statusIsError = false
        Task.detached { [client] in
            do {
                let message = try client.codexLogin()
                await MainActor.run {
                    self.busy = false
                    self.status = message.split(separator: "\n").first.map(String.init)
                        ?? "signed in"
                    self.statusIsError = false
                    self.refreshCodexAccount()
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.status = error.localizedDescription
                    self.statusIsError = true
                }
            }
        }
    }

    func codexLogout() {
        guard !busy else { return }
        busy = true
        Task.detached { [client] in
            let message = (try? client.codexLogout()) ?? "signed out"
            await MainActor.run {
                self.busy = false
                self.status = message
                self.statusIsError = false
                self.codexAccount = nil
            }
        }
    }

    func apply(preset: EnhancerConfigData.PresetData) {
        auth = preset.auth
        endpoint = preset.endpoint
        if !preset.model.isEmpty { model = preset.model }
    }

    func save(thenTest: Bool = false) {
        guard !busy else { return }
        busy = true
        status = thenTest ? "Saving and testing…" : "Saving…"
        statusIsError = false
        let payload = (auth: auth, endpoint: endpoint, model: model, key: key,
                       timeout: timeout, fbEndpoint: fallbackEndpoint,
                       fbModel: fallbackModel, fbKey: fallbackKey)
        Task.detached { [client] in
            do {
                _ = try client.setEnhancer(
                    auth: payload.auth, endpoint: payload.endpoint, model: payload.model,
                    key: payload.key.isEmpty ? nil : payload.key, timeout: payload.timeout,
                    fallbackEndpoint: payload.fbEndpoint, fallbackModel: payload.fbModel,
                    fallbackKey: payload.fbKey.isEmpty ? nil : payload.fbKey)
                let result = thenTest ? try client.testEnhancer() : nil
                await MainActor.run {
                    self.busy = false
                    self.key = ""; self.fallbackKey = ""
                    self.status = result ?? "Saved"
                    self.statusIsError = false
                    self.load()
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.status = error.localizedDescription
                    self.statusIsError = true
                    self.load()
                }
            }
        }
    }
}

struct EnhancerEditor: View {
    @ObservedObject var model: EnhancerEditorModel
    /// Nil when this is a pane in the Settings window rather than a sheet:
    /// a window with a close button does not also need a Done button.
    var onDone: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: Tokens.Space.row) {
                    Text("Build with").font(Tokens.FontScale.sectionHeader)
                    Text("The model that writes your prompts. The only thing here that spends money")
                        .font(Tokens.FontScale.tiny).foregroundStyle(.secondary)
                }
                Spacer()
                if let onDone { Button("Done", action: onDone).keyboardShortcut(.defaultAction) }
            }
            .chromeBar()
            SeedbedDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.snug) {
                    FormField("Provider preset, which fills the rest in") {
                        Menu {
                            ForEach(model.data?.presets ?? []) { preset in
                                Button(preset.name) { model.apply(preset: preset) }
                            }
                        } label: {
                            Text(model.data?.presets.first { $0.auth == model.auth
                                 && ($0.endpoint == model.endpoint || $0.endpoint.isEmpty) }?.name
                                 ?? "Custom")
                        }
                        .frame(maxWidth: 420, alignment: .leading)
                    }

                    FormField("Authentication") {
                        Picker("", selection: $model.auth) {
                            Text("Claude Code CLI (no key)").tag("cli")
                            Text("Anthropic SDK").tag("sdk")
                            Text("API key / local server").tag("api_key")
                            Text("Azure OpenAI (api-key header)").tag("azure_api_key")
                            Text("ChatGPT sign-in (no API key)").tag("chatgpt_oauth")
                        }
                        .labelsHidden().pickerStyle(.radioGroup)
                    }

                    if model.auth == "chatgpt_oauth" {
                        FormField("ChatGPT account") {
                            VStack(alignment: .leading, spacing: Tokens.Space.row) {
                                Text(model.codexAccount ?? "Not signed in")
                                    .font(Tokens.FontScale.body)
                                    .foregroundStyle(model.codexAccount == nil
                                                     ? Color.secondary : .primary)
                                HStack(spacing: Tokens.Space.tight) {
                                    Button(model.codexAccount == nil
                                           ? "Sign in with ChatGPT…" : "Sign in again…") {
                                        model.codexLogin()
                                    }
                                    .disabled(model.busy)
                                    if model.codexAccount != nil {
                                        Button("Sign out") { model.codexLogout() }
                                            .disabled(model.busy)
                                    }
                                }
                                Caption("Opens your browser. The tokens go straight to "
                                        + "your login Keychain and never into a file.")
                            }
                        }
                    }

                    if model.needsEndpoint {
                        FormField("Endpoint: https, or http only to localhost or your LAN") {
                            TextField("https://api.openai.com/v1/chat/completions",
                                      text: $model.endpoint)
                                .textFieldStyle(.roundedBorder)
                                .font(Tokens.FontScale.monoSmall)
                        }
                        FormField("Model") {
                            TextField("gpt-4o-mini", text: $model.model)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                        }
                    } else {
                        FormField("Model") {
                            TextField("opus", text: $model.model)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                        }
                    }

                    if model.needsKey {
                        FormField(model.data?.hasKey == true
                              ? "API key: one is stored, type to replace it"
                              : "API key, stored in the login Keychain and never in a file") {
                            SecureField(model.data?.hasKey == true ? "••••••••" : "sk-…",
                                        text: $model.key)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                        }
                    }

                    DisclosureGroup("Fallback, tried once if the primary fails retryably") {
                        VStack(alignment: .leading, spacing: Tokens.Space.medium) {
                            TextField("Fallback endpoint", text: $model.fallbackEndpoint)
                                .textFieldStyle(.roundedBorder)
                                .font(Tokens.FontScale.monoSmall)
                            HStack(spacing: Tokens.Space.tight) {
                                TextField("Fallback model", text: $model.fallbackModel)
                                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                                SecureField(model.data?.hasFallbackKey == true ? "••••••••" : "Fallback key",
                                            text: $model.fallbackKey)
                                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                            }
                            Text("A rate limit or a 5xx moves to the fallback; a 401 or 404 does not, "
                                 + "because the same body would fail there too.")
                                .font(Tokens.FontScale.tiny).foregroundStyle(.secondary)
                        }
                        .padding(.top, Tokens.Space.tight)
                    }
                    .font(Tokens.FontScale.small)

                    FormField("Timeout in seconds. A build is one long request") {
                        TextField("300", value: $model.timeout, format: .number)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 90)
                    }
                }
                .padding(Tokens.Space.pane)
            }

            SeedbedDivider()
            HStack(spacing: Tokens.Space.tight) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(Tokens.FontScale.small)
                    .foregroundStyle(model.statusIsError ? Tokens.danger : .secondary)
                    .lineLimit(2)
                Spacer()
                Button("Test") { model.save(thenTest: true) }.disabled(model.busy)
                Button("Save") { model.save() }
                    .disabled(model.busy).seedbedProminent()
            }
            .chromeBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
