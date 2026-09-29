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

    /// Refresh fields and key-present indicators without erasing a Test result.
    func load(preservingStatus: Bool = false) {
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
                if !preservingStatus {
                    self.status = loaded.problems.first ?? loaded.summary
                    self.statusIsError = !loaded.problems.isEmpty
                }
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
        model = preset.model
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
                    self.load(preservingStatus: thenTest)
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.status = error.localizedDescription
                    self.statusIsError = true
                    self.load(preservingStatus: true)
                }
            }
        }
    }
}

struct EnhancerEditor: View {
    @ObservedObject var model: EnhancerEditorModel
    var onDone: (() -> Void)?

    private var selectedPreset: String? {
        model.data?.presets.first {
            $0.auth == model.auth && $0.endpoint == model.endpoint && $0.model == model.model
        }?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                WorkingHeader(title: "Building", subtitle: "Choose the provider that writes your prompts.")
                if let onDone { Button("Done", action: onDone).padding(.trailing, Tokens.Space.wide) }
            }
            SeedbedDivider()
            HStack(spacing: 0) {
                providers.frame(width: ModelsMetrics.listWidth)
                SeedbedDivider()
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Tokens.Space.wide) {
                            SettingsGroup("Connection") {
                                FormField("Authentication") {
                                    Picker("Authentication", selection: $model.auth) {
                                        Text("Claude Code CLI").tag("cli")
                                        Text("Anthropic SDK").tag("sdk")
                                        Text("API key / local server").tag("api_key")
                                        Text("Azure OpenAI").tag("azure_api_key")
                                        Text("ChatGPT sign-in").tag("chatgpt_oauth")
                                    }.labelsHidden().pickerStyle(.menu)
                                    Caption(authenticationHelp)
                                }
                                if model.auth == "chatgpt_oauth" { account }
                                if model.needsEndpoint {
                                    FormField("Endpoint") {
                                        TextField("https://api.openai.com/v1/chat/completions", text: $model.endpoint)
                                            .textFieldStyle(.roundedBorder).font(Tokens.FontScale.monoSmall)
                                    }
                                    Caption("Use HTTPS for public providers. HTTP works for localhost or a server on your LAN.")
                                }
                                FormField(model.auth == "azure_api_key" ? "Deployment / model id" : "Model id") {
                                    TextField(model.needsEndpoint ? "Your provider's model id" : "opus", text: $model.model)
                                        .textFieldStyle(.roundedBorder)
                                }
                                if model.needsKey {
                                    FormField("API key") {
                                        SecureField(model.data?.hasKey == true ? "Stored key (leave blank to keep)" : "Enter API key", text: $model.key)
                                            .textFieldStyle(.roundedBorder)
                                        Caption("Stored in your login Keychain. Enter a new key to replace it.")
                                    }
                                }
                            }
                            SeedbedDivider()
                            DisclosureGroup("Fallback connection") {
                                VStack(alignment: .leading, spacing: Tokens.Space.snug) {
                                    Caption("Tried once after a rate limit or server error. Authentication and model errors stay on the primary connection.")
                                    FormField("Fallback endpoint") {
                                        TextField("https://…", text: $model.fallbackEndpoint)
                                            .textFieldStyle(.roundedBorder).font(Tokens.FontScale.monoSmall)
                                    }
                                    FormField("Fallback model id") {
                                        TextField("Model id", text: $model.fallbackModel).textFieldStyle(.roundedBorder)
                                    }
                                    FormField("Fallback API key") {
                                        SecureField(model.data?.hasFallbackKey == true ? "Stored key (leave blank to keep)" : "Enter API key", text: $model.fallbackKey)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }.padding(.top, Tokens.Space.snug)
                            }
                            FormField("Request timeout") {
                                HStack(spacing: Tokens.Space.tight) {
                                    TextField("300", value: $model.timeout, format: .number)
                                        .textFieldStyle(.roundedBorder).frame(width: 80)
                                    Text("seconds").foregroundStyle(.secondary)
                                }
                                Caption("Allow more time for a slow local model or a large prompt.")
                            }
                            DisclosureGroup("Help with providers and testing") {
                                SettingsBullets([
                                    ("Provider", "fills the connection fields as a starting point. Changes are applied when you save."),
                                    ("Custom / your own server", "works with a compatible model running on another machine. Replace the endpoint with its address."),
                                    ("Models", "chooses the target profiles your prompts are written for. This Building pane chooses who writes them."),
                                    ("Test", "saves this connection and makes one real model call. Your provider may charge for it."),
                                    ("Save", "writes the connection settings without making a model call."),
                                ]).padding(.top, Tokens.Space.snug)
                            }
                        }
                        .font(Tokens.FontScale.body)
                        .frame(maxWidth: Tokens.Width.reading, alignment: .leading)
                        .padding(Tokens.Space.wide)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    SeedbedDivider()
                    HStack(spacing: Tokens.Space.tight) {
                        Button("Save") { model.save() }.disabled(model.busy).seedbedProminent().fixedSize()
                        Button("Test") { model.save(thenTest: true) }.disabled(model.busy).fixedSize()
                            .help("Saves and makes one real model call; your provider may charge for it.")
                        if model.busy { ProgressView().controlSize(.small) }
                        Text(model.status).font(Tokens.FontScale.tiny)
                            .foregroundStyle(model.statusIsError ? Tokens.danger : .secondary)
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    }.chromeBar()
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var providers: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Providers").font(Tokens.FontScale.small.weight(.semibold))
                .padding(Tokens.Space.snug)
            SeedbedDivider()
            ScrollView {
                LazyVStack(spacing: Tokens.Space.row) {
                    ForEach(model.data?.presets ?? []) { preset in
                        Button { model.apply(preset: preset) } label: {
                            VStack(alignment: .leading, spacing: Tokens.Space.row) {
                                Text(preset.name.components(separatedBy: " (").first ?? preset.name)
                                    .font(Tokens.FontScale.body.weight(.medium)).lineLimit(1)
                                Text(authLabel(preset.auth)).font(Tokens.FontScale.tiny).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Tokens.Space.tight)
                            .frame(height: ModelsMetrics.rowHeight)
                            .background(selectedPreset == preset.id ? Tokens.Fill.selected : .clear,
                                        in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).help(preset.name)
                    }
                }.padding(Tokens.Space.row6)
            }
            SeedbedDivider()
            Caption("Select a provider, then review and save its connection.")
                .font(Tokens.FontScale.tiny).padding(Tokens.Space.snug)
        }
    }

    private var account: some View {
        FormField("ChatGPT account") {
            Text(model.codexAccount ?? "Not signed in")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Tokens.Space.tight) { accountButtons }
                VStack(alignment: .leading, spacing: Tokens.Space.tight) { accountButtons }
            }
        }
    }

    @ViewBuilder private var accountButtons: some View {
        Button(model.codexAccount == nil ? "Sign in with ChatGPT…" : "Sign in again…") { model.codexLogin() }
            .disabled(model.busy)
        if model.codexAccount != nil { Button("Sign out") { model.codexLogout() }.disabled(model.busy) }
    }

    private func authLabel(_ auth: String) -> String {
        switch auth {
        case "cli": "CLI · no API key"
        case "sdk": "Anthropic SDK"
        case "chatgpt_oauth": "ChatGPT subscription"
        case "azure_api_key": "Azure API key"
        default: "API key / local server"
        }
    }

    private var authenticationHelp: String {
        switch model.auth {
        case "cli": "Uses the Claude Code CLI installed on this Mac and its existing sign-in."
        case "sdk": "Uses ANTHROPIC_API_KEY or an existing ant login."
        case "azure_api_key": "Uses your Azure endpoint and deployment with an api-key header."
        case "chatgpt_oauth": "Uses your ChatGPT subscription. Sign-in opens a browser; tokens stay in Keychain."
        default: "Connects to an OpenAI-compatible provider or your own model server."
        }
    }
}
