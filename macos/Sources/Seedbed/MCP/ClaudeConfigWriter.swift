import Foundation

/// Writing the `mcpServers.seedbed` block of a client's own configuration file.
///
/// Seedbed is the only thing that knows the current port and the current
/// tokens, and until now it handed them over through a snippet somebody had to
/// copy by hand. That re-copy is the point of failure: every token rotation and
/// every port change silently breaks every client already configured, and the
/// break arrives as HTTP 401, which accuses the credential when the cause may
/// be the address.
///
/// The decision recorded on 2026-09-07 was to fix that with an explicit button
/// rather than an automatic write, so the app never edits another program's
/// file on a schedule nobody asked for.
///
/// ## The rule this type exists to keep
///
/// **Only the `mcpServers.seedbed` value changes. Every other byte of the file
/// is carried through untouched.** That file holds the whole of somebody's
/// Claude Code configuration, including every other MCP server they have set
/// up, and it is not ours to reformat, re-indent or re-serialise. Decoding the
/// document and encoding it again would rewrite the entire file — key order,
/// indentation, spacing, number formatting — and would look like a diff nobody
/// asked for even when the values are right.
///
/// So the edit is a splice: the document is scanned for the byte range of the
/// one value being replaced, and that range alone is swapped out. The scanner
/// below is the whole reason this is a separate type.
///
/// ## Why it is a pure function
///
/// The file lives outside this repository, on the client machine, so nothing in
/// the repo's suite can exercise the live path. What the suite *can* do is take
/// the edit as a function from string to string and check the byte-identical
/// guarantee directly, with no real file anywhere near it. `rewriting` is that
/// function; `ClaudeConfigInstaller` is the thin, untested-by-necessity shell
/// that does the backup and the write around it.
enum ClaudeConfig {
    /// The key this app owns inside `mcpServers`. Nothing else is ever touched.
    static let serverName = "seedbed"

    /// What the edit did, so the caller can say which of the two happened. A
    /// person who has never configured the server sees a different sentence
    /// from one whose entry was refreshed, and conflating them hides the case
    /// where the app wrote into a file the client was not reading.
    enum Change: Equatable {
        case replaced
        case created
    }

    /// Why an edit did not happen. None of these carry a token or any part of
    /// the file: a failure path is exactly where a secret leaks into a log.
    enum Failure: Error, Equatable {
        /// Valid JSON was not found. The file is refused rather than replaced,
        /// because the alternative is destroying a configuration that is
        /// probably recoverable by hand.
        case malformed
        /// The document parses but is not shaped like a configuration file:
        /// `mcpServers` is present and is not an object, so there is no safe
        /// place to put the entry.
        case unexpectedShape
    }

    /// The rewritten document, and which of the two things happened to it.
    struct Rewrite: Equatable {
        let text: String
        let change: Change
    }

    /// Return `text` with `mcpServers.seedbed` set to this url and token, and
    /// every other byte of `text` unchanged.
    ///
    /// - Throws: `Failure.malformed` when the document is not a JSON object,
    ///   `Failure.unexpectedShape` when `mcpServers` exists but is not one.
    static func rewriting(_ text: String, url: String, token: String) throws -> Rewrite {
        // Parse the whole document once before touching it. The span scanner
        // below is deliberately narrow and would happily splice into something
        // that only looks like JSON, so the real parser is the gate: a file we
        // cannot fully read is a file we must not write.
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data),
              root is [String: Any]
        else { throw Failure.malformed }

        let bytes = Array(text.utf8)
        var cursor = 0
        JSONSpan.skipWhitespace(bytes, &cursor)
        guard cursor < bytes.count, bytes[cursor] == JSONSpan.openBrace else {
            throw Failure.malformed
        }
        let rootStart = cursor
        let rootMembers = try JSONSpan.members(bytes, objectAt: rootStart)

        guard let servers = rootMembers.first(where: { $0.key == "mcpServers" }) else {
            // No `mcpServers` key at all. A first-run file, or one that has only
            // ever held Claude Code's own settings.
            let closeIndent = JSONSpan.columnIndent(bytes, at: rootStart)
            let memberIndent = JSONSpan.memberIndent(
                bytes, objectAt: rootStart, fallback: closeIndent + "  "
            )
            let block = "\"mcpServers\": {\n"
                + "\(memberIndent)  \"\(serverName)\": "
                + entry(indent: memberIndent + "  ", url: url, token: token) + "\n"
                + "\(memberIndent)}"
            return Rewrite(
                text: JSONSpan.inserting(block, into: bytes, objectAt: rootStart,
                                         memberIndent: memberIndent, closeIndent: closeIndent),
                change: .created
            )
        }

        guard servers.valueStart < bytes.count,
              bytes[servers.valueStart] == JSONSpan.openBrace
        else { throw Failure.unexpectedShape }

        let existing = try JSONSpan.members(bytes, objectAt: servers.valueStart)
        if let mine = existing.first(where: { $0.key == serverName }) {
            // The one case that has to be surgical: splice over the value and
            // nothing else, so a file with six other servers in it comes back
            // byte-identical everywhere but here.
            let indent = JSONSpan.columnIndent(bytes, at: mine.keyStart)
            var out = bytes
            out.replaceSubrange(
                mine.valueStart..<mine.valueEnd,
                with: Array(entry(indent: indent, url: url, token: token).utf8)
            )
            return Rewrite(text: String(decoding: out, as: UTF8.self), change: .replaced)
        }

        // `mcpServers` is there and holds other servers, or none. Add ours as a
        // new member without disturbing any of them.
        let closeIndent = JSONSpan.columnIndent(bytes, at: servers.keyStart)
        let memberIndent = JSONSpan.memberIndent(
            bytes, objectAt: servers.valueStart, fallback: closeIndent + "  "
        )
        let block = "\"\(serverName)\": " + entry(indent: memberIndent, url: url, token: token)
        return Rewrite(
            text: JSONSpan.inserting(block, into: bytes, objectAt: servers.valueStart,
                                     memberIndent: memberIndent, closeIndent: closeIndent),
            change: .created
        )
    }

    /// The value written under `seedbed`, laid out against `indent`, which is
    /// the column its own key sits at.
    ///
    /// `"type": "http"` is required rather than decorative, for the same reason
    /// the copyable snippet carries it: a client left to infer the transport can
    /// dial the URL and never send the `headers` block, which arrives at the far
    /// end as an unauthenticated request and reports as a bad token.
    static func entry(indent: String, url: String, token: String) -> String {
        """
        {
        \(indent)  "type": "http",
        \(indent)  "url": \(JSONSpan.quoted(url)),
        \(indent)  "headers": {
        \(indent)    "Authorization": \(JSONSpan.quoted("Bearer " + token))
        \(indent)  }
        \(indent)}
        """
    }
}

/// A scanner that locates JSON values by byte range instead of decoding them.
///
/// Everything here works on UTF-8 bytes and returns offsets into them, because
/// the guarantee being kept is about bytes: the parts of the file we are not
/// editing must survive the round trip exactly, and any conversion through a
/// model object loses that by construction.
private enum JSONSpan {
    static let openBrace: UInt8 = 0x7B      // {
    static let closeBrace: UInt8 = 0x7D     // }
    static let openBracket: UInt8 = 0x5B    // [
    static let closeBracket: UInt8 = 0x5D   // ]
    static let quote: UInt8 = 0x22          // "
    static let backslash: UInt8 = 0x5C      // \
    static let colon: UInt8 = 0x3A          // :
    static let comma: UInt8 = 0x2C          // ,
    static let newline: UInt8 = 0x0A

    /// One member of an object, with the offsets needed to splice it.
    struct Member {
        let key: String
        /// The opening quote of the key, used to read the column it sits at.
        let keyStart: Int
        let valueStart: Int
        /// One past the last byte of the value.
        let valueEnd: Int
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    static func skipWhitespace(_ bytes: [UInt8], _ index: inout Int) {
        while index < bytes.count, isWhitespace(bytes[index]) { index += 1 }
    }

    /// One past the string literal beginning at `start`.
    static func endOfString(_ bytes: [UInt8], _ start: Int) throws -> Int {
        guard start < bytes.count, bytes[start] == quote else {
            throw ClaudeConfig.Failure.malformed
        }
        var index = start + 1
        while index < bytes.count {
            if bytes[index] == backslash { index += 2; continue }
            if bytes[index] == quote { return index + 1 }
            index += 1
        }
        throw ClaudeConfig.Failure.malformed
    }

    /// One past a balanced `{...}` or `[...]` beginning at `start`. Braces
    /// inside string literals are skipped, which is the whole difficulty.
    static func endOfNested(_ bytes: [UInt8], _ start: Int) throws -> Int {
        var depth = 0
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == quote { index = try endOfString(bytes, index); continue }
            if byte == openBrace || byte == openBracket { depth += 1 }
            if byte == closeBrace || byte == closeBracket {
                depth -= 1
                if depth == 0 { return index + 1 }
                if depth < 0 { throw ClaudeConfig.Failure.malformed }
            }
            index += 1
        }
        throw ClaudeConfig.Failure.malformed
    }

    /// One past any value beginning at `start`.
    static func endOfValue(_ bytes: [UInt8], _ start: Int) throws -> Int {
        guard start < bytes.count else { throw ClaudeConfig.Failure.malformed }
        switch bytes[start] {
        case quote:
            return try endOfString(bytes, start)
        case openBrace, openBracket:
            return try endOfNested(bytes, start)
        default:
            // A number, `true`, `false` or `null`: it runs to the first byte
            // that can only belong to the enclosing object.
            var index = start
            while index < bytes.count {
                let byte = bytes[index]
                if byte == comma || byte == closeBrace || byte == closeBracket
                    || isWhitespace(byte) { break }
                index += 1
            }
            guard index > start else { throw ClaudeConfig.Failure.malformed }
            return index
        }
    }

    /// The members of the object whose `{` is at `start`, in file order.
    static func members(_ bytes: [UInt8], objectAt start: Int) throws -> [Member] {
        guard start < bytes.count, bytes[start] == openBrace else {
            throw ClaudeConfig.Failure.unexpectedShape
        }
        var found: [Member] = []
        var index = start + 1
        while true {
            skipWhitespace(bytes, &index)
            guard index < bytes.count else { throw ClaudeConfig.Failure.malformed }
            if bytes[index] == closeBrace { return found }
            guard bytes[index] == quote else { throw ClaudeConfig.Failure.malformed }

            let keyStart = index
            let keyEnd = try endOfString(bytes, index)
            guard let key = decodedString(bytes, keyStart, keyEnd) else {
                throw ClaudeConfig.Failure.malformed
            }
            index = keyEnd
            skipWhitespace(bytes, &index)
            guard index < bytes.count, bytes[index] == colon else {
                throw ClaudeConfig.Failure.malformed
            }
            index += 1
            skipWhitespace(bytes, &index)
            let valueStart = index
            let valueEnd = try endOfValue(bytes, index)
            found.append(Member(key: key, keyStart: keyStart,
                                valueStart: valueStart, valueEnd: valueEnd))

            index = valueEnd
            skipWhitespace(bytes, &index)
            guard index < bytes.count else { throw ClaudeConfig.Failure.malformed }
            if bytes[index] == comma { index += 1; continue }
            if bytes[index] == closeBrace { return found }
            throw ClaudeConfig.Failure.malformed
        }
    }

    /// A key's text, decoded through the real parser so `\u` escapes in a key
    /// name are understood rather than compared literally.
    static func decodedString(_ bytes: [UInt8], _ start: Int, _ end: Int) -> String? {
        let slice = Data(bytes[start..<end])
        let value = try? JSONSerialization.jsonObject(with: slice, options: [.fragmentsAllowed])
        return value as? String
    }

    /// The run of spaces or tabs between the last newline and `index`, or the
    /// empty string when anything else sits in between. That is the column the
    /// thing at `index` starts at, which is what new lines have to line up with.
    static func columnIndent(_ bytes: [UInt8], at index: Int) -> String {
        var start = index
        while start > 0, bytes[start - 1] != newline {
            let byte = bytes[start - 1]
            guard byte == 0x20 || byte == 0x09 else { return "" }
            start -= 1
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    /// The column this object's existing members sit at, so an inserted one
    /// matches the file's own indentation rather than imposing a house style.
    /// `fallback` covers an empty object and one written on a single line.
    static func memberIndent(_ bytes: [UInt8], objectAt start: Int, fallback: String) -> String {
        var index = start + 1
        var sawNewline = false
        while index < bytes.count, isWhitespace(bytes[index]) {
            if bytes[index] == newline { sawNewline = true }
            index += 1
        }
        guard sawNewline, index < bytes.count, bytes[index] != closeBrace else { return fallback }
        return columnIndent(bytes, at: index)
    }

    /// `block` inserted as the first member of the object whose `{` is at
    /// `start`. First rather than last because it needs no edit to the member
    /// before it: appending would mean adding a comma to a line we do not own,
    /// and that line would then differ for no reason the reader can see.
    static func inserting(_ block: String, into bytes: [UInt8], objectAt start: Int,
                          memberIndent: String, closeIndent: String) -> String {
        var index = start + 1
        skipWhitespace(bytes, &index)
        let isEmpty = index < bytes.count && bytes[index] == closeBrace

        var out = bytes
        if isEmpty {
            // `{}` or `{\n}`: there is no member to sit in front of, so the
            // whitespace between the braces is ours to write.
            let text = "\n\(memberIndent)\(block)\n\(closeIndent)"
            out.replaceSubrange((start + 1)..<index, with: Array(text.utf8))
        } else {
            let text = "\n\(memberIndent)\(block),"
            out.insert(contentsOf: Array(text.utf8), at: start + 1)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// A JSON string literal. Written out rather than routed through
    /// `JSONSerialization`, which would escape a forward slash in a URL and
    /// produce a correct document that reads as mangled.
    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// The thin shell around `ClaudeConfig.rewriting`: find the file, back it up,
/// write it, and say what happened.
///
/// Everything here touches the filesystem and none of it can be exercised by
/// this repository's suite, which is exactly why it is kept this small. The
/// decisions live in the pure function; this does the four steps in order and
/// turns each outcome into a sentence.
enum ClaudeConfigInstaller {
    /// What the pane shows afterwards. A write that reports nothing is
    /// indistinguishable from one that failed, which is how the original
    /// problem stayed invisible for as long as it did.
    struct Report: Equatable {
        let succeeded: Bool
        let title: String
        let detail: String
    }

    /// The file every MCP client on this Mac reads. Overridable only so a test
    /// harness has somewhere else to point; the app never passes anything else.
    static var defaultPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Point the client's `seedbed` entry at this url and token.
    ///
    /// - Important: `token` must be the **read-only** one. A client configured
    ///   by a button press has not been trusted with anything; handing it the
    ///   full token would let it rebuild a prompt and spend an LLM call.
    ///   Nothing here logs, prints or returns the token, and no message below
    ///   contains any part of it.
    @discardableResult
    static func update(url: String, token: String,
                       at path: String = defaultPath,
                       now: Date = Date()) -> Report {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else {
            return Report(
                succeeded: false,
                title: "There is no configuration file to update.",
                detail: "Seedbed looked for \(displayPath(path)) and found nothing there. "
                    + "Copy the configuration above into your client instead, and this "
                    + "button will keep it current from then on."
            )
        }
        guard let data = manager.contents(atPath: path),
              let text = String(data: data, encoding: .utf8)
        else {
            return Report(
                succeeded: false,
                title: "Seedbed could not read your configuration file.",
                detail: "\(displayPath(path)) could not be opened, so nothing was changed. "
                    + "Check that you have permission to read it, then try again."
            )
        }

        let rewrite: ClaudeConfig.Rewrite
        do {
            rewrite = try ClaudeConfig.rewriting(text, url: url, token: token)
        } catch ClaudeConfig.Failure.unexpectedShape {
            return Report(
                succeeded: false,
                title: "The mcpServers section is not in the expected shape.",
                detail: "\(displayPath(path)) has an mcpServers entry that is not a set of "
                    + "servers, so Seedbed left the file alone rather than guess. Copy the "
                    + "configuration above in by hand."
            )
        } catch {
            return Report(
                succeeded: false,
                title: "Your configuration file is not valid JSON.",
                detail: "Seedbed could not read \(displayPath(path)) as JSON and changed "
                    + "nothing, because replacing a file it cannot parse would lose whatever "
                    + "is in there. Fix the file, or copy the configuration above in by hand."
            )
        }

        // Back up before writing, never after. The backup is the whole reason
        // this is safe to press, so a failure here stops the write.
        let backup = "\(path).bak-\(timestamp(now))"
        do {
            try data.write(to: URL(fileURLWithPath: backup), options: [.atomic])
        } catch {
            return Report(
                succeeded: false,
                title: "Seedbed could not save a backup, so it changed nothing.",
                detail: "It tried to copy your configuration to \(displayPath(backup)) first "
                    + "and could not. Check that you have permission to write to that folder."
            )
        }
        do {
            try Data(rewrite.text.utf8).write(to: URL(fileURLWithPath: path), options: [.atomic])
        } catch {
            return Report(
                succeeded: false,
                title: "Seedbed could not write your configuration file.",
                detail: "\(displayPath(path)) was left as it was, and a copy of it is at "
                    + "\(displayPath(backup)). Check that you have permission to write to it."
            )
        }

        let opening = rewrite.change == .replaced
            ? "Updated the seedbed entry in \(displayPath(path))."
            : "Added a seedbed entry to \(displayPath(path))."
        return Report(
            succeeded: true,
            title: opening,
            detail: "It now points at \(url) with the read-only token, and nothing else in "
                + "the file was touched. The previous version is at \(displayPath(backup)). "
                + "Restart your client to pick the change up."
        )
    }

    /// A path with the home directory written the way a person reads it.
    static func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
