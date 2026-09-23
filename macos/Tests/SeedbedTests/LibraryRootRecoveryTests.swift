import XCTest
@testable import Seedbed

/// A cached window must not strand every library action on a folder that is no
/// longer a checkout. These tests exercise the resolver as values so they do
/// not read or write the developer's real library preference.
final class LibraryRootRecoveryTests: XCTestCase {
    private let invalid = URL(fileURLWithPath: "/tmp/not-a-seedbed-library")

    func testAValidPreferredLibraryStillWins() {
        let resolved = LibraryClient.resolveUsableRoot(preferred: invalid) { url in
            url == self.invalid
        }
        XCTAssertEqual(resolved, invalid)
    }

    func testAnInvalidCachedRootRecoversToTheValidLegacyCheckout() {
        let resolved = LibraryClient.resolveUsableRoot(
            preferred: LibraryClient.commonRoot
        ) { url in
            url == LibraryClient.legacyDefaultRoot
        }
        XCTAssertEqual(resolved, LibraryClient.legacyDefaultRoot)
    }

    func testAnInvalidLegacyDefaultRecoversToTheCommonCheckout() {
        let resolved = LibraryClient.resolveUsableRoot(
            preferred: LibraryClient.legacyDefaultRoot
        ) { url in
            url == LibraryClient.commonRoot
        }
        XCTAssertEqual(resolved, LibraryClient.commonRoot)
    }

    func testAnInvalidCustomSelectionNeverSilentlyChangesRepositories() {
        let resolved = LibraryClient.resolveUsableRoot(preferred: invalid) { url in
            url == LibraryClient.legacyDefaultRoot
        }
        XCTAssertEqual(resolved, invalid)
    }

    func testWithoutAValidFallbackTheOriginalFolderNamesTheError() {
        let resolved = LibraryClient.resolveUsableRoot(preferred: invalid) { _ in false }
        XCTAssertEqual(resolved, invalid)
    }
}
