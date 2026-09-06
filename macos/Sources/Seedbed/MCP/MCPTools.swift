import Foundation

/// The tools an agent can call, and the prompts it can pull.
///
/// Every one of them runs `python3 -m promptlib` through `LibraryClient`. The
/// app is a front end and this is a second front end onto the same package, so
/// staleness, guidance, the enhancer and the matcher keep exactly one
/// implementation. Parsing the library in Swift for the MCP server's benefit is
/// the drift this architecture exists to prevent.
enum MCPToolCatalog {
    struct Outcome {
        let text: String
        let isError: Bool

        static func ok(_ text: String) -> Outcome { Outcome(text: text, isError: false) }
        static func failed(_ text: String) -> Outcome { Outcome(text: text, isError: true) }
    }

    /// Tools the read-only token may call.
    ///
    /// The split matters more here than in a library of notes: `build_prompt`
    /// spends an LLM call, and a client that only wants to read a prompt has no
    /// business running one. Everything else only reads files.
    static let readOnlyTools: Set<String> = [
        "list_prompts", "get_prompt", "find_prompt", "list_models",
    ]

    // MARK: - Definitions

    static let definitions: [[String: Any]] = [
        [
            "name": "find_prompt",
            "description": """
            Find the prompt that serves a described task, when you do not know \
            what it is called. Give the ask in your own words, such as "reviewing a \
            diff before I merge", "the one for explaining code". Matches on \
            meaning, not just wording, and returns the best candidate first \
            with the evidence for it plus the alternatives. Pass `model` to get \
            that model's tailored version of the winner in the same answer, \
            which is what you want when the goal is to use the prompt rather \
            than to look it up. Start here rather than with list_prompts.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ask": [
                        "type": "string",
                        "description": "What you are looking for, in your own words.",
                    ],
                    "model": [
                        "type": "string",
                        "description": "Optional model id. Returns that model's render "
                            + "of the winning prompt alongside the match. See list_models.",
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "How many candidates to return. Default 5.",
                    ],
                    "semantic": [
                        "type": "boolean",
                        "description": "Let a model break a tie when the text match is "
                            + "ambiguous. Default true. Set false to stay purely lexical "
                            + "and instant.",
                    ],
                ],
                "required": ["ask"],
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "get_prompt",
            "description": """
            The full text of one prompt by its exact id. With `model`, returns \
            that model's tailored version and says whether it is current or \
            stale; without one, returns the short seed the tailored versions \
            are generated from. Use find_prompt when you do not already know \
            the id.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The prompt's id, e.g. review-my-diff."],
                    "model": [
                        "type": "string",
                        "description": "Optional model id. Omit for the seed itself.",
                    ],
                ],
                "required": ["id"],
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "list_prompts",
            "description": """
            Every prompt in the library: id, title, the seed text, category, \
            tags, and which models it has been built for with each render's \
            state. Use it to browse; use find_prompt to search.
            """,
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "list_models",
            "description": """
            The target models this library builds prompts for — the ids \
            accepted by get_prompt and find_prompt. A target is a prompting \
            profile, not an API connection: listing one calls no vendor.
            """,
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "build_prompt",
            "description": """
            Generate or regenerate one prompt's tailored version for one model. \
            This spends an LLM call and takes about a minute, so call it only \
            when a render is missing or stale and you actually need it — \
            get_prompt tells you which. Refused for a client using the \
            read-only token.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The prompt's id."],
                    "model": ["type": "string", "description": "The target model's id."],
                    "force": [
                        "type": "boolean",
                        "description": "Rebuild even when the render is already current. "
                            + "Default false.",
                    ],
                ],
                "required": ["id", "model"],
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": true],
        ],
    ]

    /// The library's prompts, as MCP prompt definitions.
    static func promptDefinitions(_ data: LibraryData) -> [[String: Any]] {
        data.seeds.map { seed in
            [
                "name": seed.id,
                "description": seed.title.isEmpty ? seed.body : "\(seed.title): \(seed.body)",
                "arguments": [[
                    "name": "model",
                    "description": "Which model's tailored version to return. "
                        + "Omit for the seed itself.",
                    "required": false,
                ]],
            ]
        }
    }

    struct RenderedPrompt {
        let description: String
        let text: String
    }

    /// One prompt, ready to hand to a client through `prompts/get`.
    static func renderPrompt(
        name: String, model: String, client: LibraryClient
    ) async throws -> RenderedPrompt {
        let data = try await detached(client) { try $0.load() }
        guard let seed = data.seeds.first(where: { $0.id == name }) else {
            throw LibraryError.commandFailed("no prompt named \(name)")
        }
        guard !model.isEmpty else {
            return RenderedPrompt(description: seed.title.isEmpty ? seed.id : seed.title,
                                  text: seed.body)
        }
        guard seed.targets.contains(where: { $0.model == model }) else {
            throw LibraryError.commandFailed(
                "\(name) is not built for \(model). Its models are: "
                    + seed.targets.map(\.model).joined(separator: ", "))
        }
        let body = try await detached(client) { try $0.render(id: name, model: model, record: true) }
        return RenderedPrompt(
            description: "\(seed.title.isEmpty ? seed.id : seed.title), tailored for \(model)",
            text: body)
    }

    // MARK: - Running a tool

    static func run(
        name: String, arguments: [String: Any], client: LibraryClient
    ) async -> Outcome {
        do {
            switch name {
            case "find_prompt":   return try await findPrompt(arguments, client)
            case "get_prompt":    return try await getPrompt(arguments, client)
            case "list_prompts":  return try await listPrompts(client)
            case "list_models":   return try await listModels(client)
            case "build_prompt":  return try await buildPrompt(arguments, client)
            default:
                return .failed("Unknown tool: \(name)")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func findPrompt(
        _ arguments: [String: Any], _ client: LibraryClient
    ) async throws -> Outcome {
        let ask = (arguments["ask"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ask.isEmpty else { return .failed("find_prompt needs an `ask`.") }
        let model = arguments["model"] as? String ?? ""
        let limit = arguments["limit"] as? Int ?? 5
        let semantic = arguments["semantic"] as? Bool ?? true
        // The JSON comes straight from `promptlib match --json`. Re-shaping it
        // here would give the answer two definitions, one of which would rot.
        let json = try await detached(client) {
            try $0.match(ask: ask, model: model, limit: max(1, limit),
                         semantic: semantic, record: !model.isEmpty)
        }
        return .ok(json)
    }

    private static func getPrompt(
        _ arguments: [String: Any], _ client: LibraryClient
    ) async throws -> Outcome {
        guard let id = arguments["id"] as? String, !id.isEmpty else {
            return .failed("get_prompt needs an `id`.")
        }
        let model = arguments["model"] as? String ?? ""
        let data = try await detached(client) { try $0.load() }
        guard let seed = data.seeds.first(where: { $0.id == id }) else {
            return .failed("No prompt with id \(id). Use find_prompt to search by description.")
        }
        if model.isEmpty {
            return .ok(encode([
                "id": seed.id,
                "title": seed.title,
                "seed": seed.body,
                "category": seed.category,
                "tags": seed.tags,
                "models": seed.targets.map { ["model": $0.model, "state": $0.state] },
                "note": "This is the short seed. Pass `model` for the tailored version.",
            ]))
        }
        guard let target = seed.targets.first(where: { $0.model == model }) else {
            return .failed("\(id) is not built for \(model). Its models are: "
                + seed.targets.map(\.model).joined(separator: ", "))
        }
        guard target.isUsable else {
            return .failed("\(id) has no render for \(model) yet. Call build_prompt to "
                + "generate it, which spends an LLM call and takes about a minute.")
        }
        let body = try await detached(client) { try $0.render(id: id, model: model, record: true) }
        return .ok(encode([
            "id": seed.id,
            "model": model,
            "state": target.state,
            "words": target.words,
            "generated": target.generated,
            "placeholders": target.variables,
            "prompt": body,
        ]))
    }

    private static func listPrompts(_ client: LibraryClient) async throws -> Outcome {
        let data = try await detached(client) { try $0.load() }
        return .ok(encode([
            "prompts": data.seeds.map { seed in
                [
                    "id": seed.id,
                    "title": seed.title,
                    "seed": seed.body,
                    "category": seed.category,
                    "tags": seed.tags,
                    "pinned": seed.pinned,
                    "uses": seed.uses,
                    "models": seed.targets.map { ["model": $0.model, "state": $0.state] },
                ]
            },
        ]))
    }

    private static func listModels(_ client: LibraryClient) async throws -> Outcome {
        let data = try await detached(client) { try $0.load() }
        return .ok(encode([
            "models": data.models.map {
                ["id": $0.id, "name": $0.name, "family": $0.family, "notes": $0.notes]
            },
        ]))
    }

    private static func buildPrompt(
        _ arguments: [String: Any], _ client: LibraryClient
    ) async throws -> Outcome {
        guard let id = arguments["id"] as? String, !id.isEmpty,
              let model = arguments["model"] as? String, !model.isEmpty
        else { return .failed("build_prompt needs an `id` and a `model`.") }
        let force = arguments["force"] as? Bool ?? false
        try await detached(client) { client in
            if force {
                try client.rebuild(id: id, model: model)
            } else {
                try client.build(id: id, model: model)
            }
        }
        let body = try await detached(client) { try $0.render(id: id, model: model) }
        return .ok(encode([
            "id": id, "model": model, "built": true,
            "words": body.split(whereSeparator: \.isWhitespace).count,
            "prompt": body,
        ]))
    }

    // MARK: - Helpers

    /// Runs one blocking `LibraryClient` call off whatever actor called it. Each
    /// of these spawns a Python process; a build takes minutes, and none of that
    /// belongs on the main actor or inside the request handler's own isolation.
    private static func detached<T: Sendable>(
        _ client: LibraryClient, _ work: @escaping @Sendable (LibraryClient) throws -> T
    ) async throws -> T {
        try await Task.detached { try work(client) }.value
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}
