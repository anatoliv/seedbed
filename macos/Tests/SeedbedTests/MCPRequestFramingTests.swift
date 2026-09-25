import XCTest
@testable import Seedbed

/// How the MCP server decides the size of a request body from its head.
///
/// This runs before the bearer token is checked, so anything a local process
/// can put in a header reaches it. A `Content-Length: -1` used to pass the
/// size cap and then trap in `Data.prefix`, taking the whole app down with one
/// request.
final class MCPRequestFramingTests: XCTestCase {
    private func length(
        _ headers: [String: String], method: String = "POST", bytesAfterHead: Int = 0
    ) throws -> Int {
        try MCPServer.declaredBodyLength(
            method: method, headers: headers, bytesAfterHead: bytesAfterHead
        )
    }

    private func assertMalformed(
        _ headers: [String: String], method: String = "POST", bytesAfterHead: Int = 0,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try length(headers, method: method, bytesAfterHead: bytesAfterHead),
            file: file, line: line
        ) { error in
            guard case MCPServerError.malformedRequest = error else {
                return XCTFail("expected malformedRequest, got \(error)", file: file, line: line)
            }
        }
    }

    // MARK: The crash

    func testANegativeContentLengthIsRefused() {
        assertMalformed(["content-length": "-1"])
        assertMalformed(["content-length": "-1000000"])
    }

    /// The exact shape of the trap: the length the parser hands on is what
    /// `readRequest` slices the body with. If a negative one ever gets through,
    /// this test crashes the test runner the way the request crashed the app.
    func testTheLengthHandedOnIsAlwaysSafeToSliceWith() {
        let body = Data("{}".utf8)
        for raw in ["-1", "-2", "-9223372036854775808"] {
            if let n = try? length(["content-length": raw], bytesAfterHead: body.count) {
                XCTAssertGreaterThanOrEqual(n, 0, "Content-Length \(raw) was accepted as \(n)")
                _ = body.prefix(n)
            }
        }
    }

    // MARK: Garbled or missing

    func testAGarbledContentLengthIsRefusedRatherThanReadAsZero() {
        for raw in ["", "abc", "12abc", "1.5", "0x10", "+5", "5, 5", "99999999999999999999999"] {
            assertMalformed(["content-length": raw])
        }
    }

    func testAPostWithNoContentLengthIsRefused() {
        assertMalformed([:])
        assertMalformed(["host": "localhost:8789"], bytesAfterHead: 0)
    }

    func testBodyBytesWithNoContentLengthAreRefusedWhateverTheMethod() {
        assertMalformed([:], method: "GET", bytesAfterHead: 2)
    }

    func testABodilessRequestWithNoContentLengthStillHasLengthZero() throws {
        // A GET or DELETE with nothing after the head is ordinary and is left to
        // the handler, which answers it with 405.
        XCTAssertEqual(try length([:], method: "GET"), 0)
        XCTAssertEqual(try length([:], method: "DELETE"), 0)
    }

    // MARK: Chunked

    func testChunkedTransferEncodingIsRefused() {
        assertMalformed(["transfer-encoding": "chunked"])
        assertMalformed(["transfer-encoding": "Chunked"])
        assertMalformed(["transfer-encoding": "gzip, chunked"])
        // Even with a Content-Length beside it: the body would be misread.
        assertMalformed(["transfer-encoding": "chunked", "content-length": "2"])
    }

    // MARK: What still works

    func testAWellFormedContentLengthIsTheLength() throws {
        XCTAssertEqual(try length(["content-length": "0"]), 0)
        XCTAssertEqual(try length(["content-length": "42"], bytesAfterHead: 42), 42)
        XCTAssertEqual(
            try length(["content-length": "\(MCPConstants.maxRequestBytes)"]),
            MCPConstants.maxRequestBytes
        )
    }

    func testTheOverSizeRefusalIsUnchanged() {
        XCTAssertThrowsError(
            try length(["content-length": "\(MCPConstants.maxRequestBytes + 1)"])
        ) { error in
            guard case MCPServerError.requestTooLarge = error else {
                return XCTFail("expected requestTooLarge, got \(error)")
            }
        }
    }

    // MARK: The answer

    func testAMalformedRequestIsAnswered400() throws {
        let response = try XCTUnwrap(MCPServer.response(refusing: MCPServerError.malformedRequest))
        XCTAssertEqual(response.status, 400)
        let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        XCTAssertEqual(object?["error"] as? String, "bad request")
    }

    func testOtherFailuresStillCloseWithoutAnAnswer() {
        // Over-size and time-out keep their existing behaviour: the connection
        // is closed, nothing is written.
        XCTAssertNil(MCPServer.response(refusing: MCPServerError.requestTooLarge))
        XCTAssertNil(MCPServer.response(refusing: MCPServerError.timedOut))
        XCTAssertNil(MCPServer.response(refusing: MCPServerError.connectionClosed))
    }
}
