import Foundation
import XCTest
@testable import Seedbed

final class PackagedPythonRuntimeTests: XCTestCase {
    func testRebuildUsesPackagedCodeWithAnOlderLibraryCopy() async throws {
        let files = FileManager.default
        let sandbox = files.temporaryDirectory
            .appendingPathComponent("seedbed-runtime-\(UUID().uuidString)", isDirectory: true)
        let runtime = sandbox.appendingPathComponent("runtime", isDirectory: true)
        let library = sandbox.appendingPathComponent("library", isDirectory: true)
        let portFile = sandbox.appendingPathComponent("port")
        let requestFile = sandbox.appendingPathComponent("request.json")
        try files.createDirectory(at: runtime, withIntermediateDirectories: true)
        try files.createDirectory(at: library.appendingPathComponent("promptlib"),
                                  withIntermediateDirectories: true)
        defer { try? files.removeItem(at: sandbox) }

        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        try files.copyItem(at: repository.appendingPathComponent("promptlib"),
                           to: runtime.appendingPathComponent("promptlib"))
        try files.copyItem(at: repository.appendingPathComponent(
            "macos/Packaging/seedbed_runtime.py"),
            to: runtime.appendingPathComponent("seedbed_runtime.py"))

        // This library looks valid to older Seedbed releases but its code must
        // never be imported by the installed app after an update.
        try "".write(to: library.appendingPathComponent("promptlib/__init__.py"),
                      atomically: true, encoding: .utf8)
        try "raise SystemExit('stale library code ran')".write(
            to: library.appendingPathComponent("promptlib/cli.py"),
            atomically: true, encoding: .utf8)
        try """
            [models.grok]
            name = "Grok 4.7"
            family = "grok"
            guides = []
            notes = "No external guidance needed."
            """.write(to: library.appendingPathComponent("models.toml"),
                      atomically: true, encoding: .utf8)
        try files.createDirectory(at: library.appendingPathComponent("prompts"),
                                  withIntermediateDirectories: true)
        try """
            +++
            title = "Test prompt"
            targets = ["grok"]
            tags = []
            +++
            Help me set this up.
            """.write(to: library.appendingPathComponent("prompts/sample.md"),
                      atomically: true, encoding: .utf8)

        let serverScript = """
            import sys
            from http.server import BaseHTTPRequestHandler, HTTPServer
            class Handler(BaseHTTPRequestHandler):
                def do_POST(self):
                    body = self.rfile.read(int(self.headers['Content-Length']))
                    with open(sys.argv[2], 'wb') as output: output.write(body)
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(b'{"choices":[{"message":{"content":"from packaged runtime"}}]}')
                def log_message(self, *args): pass
            server = HTTPServer(('127.0.0.1', 0), Handler)
            with open(sys.argv[1], 'w') as output: output.write(str(server.server_port))
            server.handle_request()
            """
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", serverScript, portFile.path, requestFile.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() } }

        var port = ""
        for _ in 0..<200 {
            port = (try? String(contentsOf: portFile, encoding: .utf8)) ?? ""
            if !port.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(port.isEmpty, "local test provider did not start")
        try """
            [enhancer]
            auth = "api_key"
            endpoint = "http://127.0.0.1:\(port)/v1/chat/completions"
            model = "writer"
            preset = "custom"
            timeout = 5
            """.write(to: library.appendingPathComponent("enhancer.toml"),
                      atomically: true, encoding: .utf8)

        let testBin = sandbox.appendingPathComponent("bin", isDirectory: true)
        try files.createDirectory(at: testBin, withIntermediateDirectories: true)
        let keychainShim = testBin.appendingPathComponent("security")
        try "#!/bin/sh\nexit 1\n".write(to: keychainShim, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: keychainShim.path)
        var childEnvironment = ProcessInfo.processInfo.environment
        childEnvironment["PATH"] = "\(testBin.path):/usr/bin:/bin"

        let client = LibraryClient(root: library, runtimeRoot: runtime,
                                   environmentOverride: childEnvironment)
        try await Task.detached { try client.rebuild(id: "sample", model: "grok") }.value

        XCTAssertEqual(try client.render(id: "sample", model: "grok"),
                       "from packaged runtime")
        let request = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: requestFile)) as? [String: Any])
        XCTAssertEqual(request["model"] as? String, "writer")
    }
}
