import SwiftUI
import Vision
import XCTest
@testable import Seedbed

@MainActor
final class MCPPortDisplayTests: XCTestCase {
    func testRenderedStatusKeepsPortsAsDigitsAcrossLocales() throws {
        for locale in ["en_US", "de_DE", "fr_FR"] {
            for port: UInt16 in [8789, 8803, 65535] {
                // Render only the production status Text. No server, tokens,
                // settings window, or live configuration enters this test.
                let renderer = ImageRenderer(content: MCPSettings.runningStatus(port: port)
                    .environment(\.locale, Locale(identifier: locale))
                    .font(.system(size: 24)).foregroundStyle(.black)
                    .padding(20).background(.white))
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: image).perform([request])
                let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
                XCTAssertEqual(lines, ["Running at http://127.0.0.1:\(port)"], locale)
            }
        }
    }
}
