import XCTest
import Security
@testable import QuickCapture

/// The sync workers read the access key every few seconds. A keychain that
/// can't hand it over must not be asked again on every poll — each ask can be
/// a password dialog.
final class OrganiserCredentialsTests: XCTestCase {
    private var lookups = 0
    override func tearDown() { OrganiserCredentials.resetForTesting(); super.tearDown() }

    private func stubKeychain(_ status: OSStatus, _ token: String? = nil) {
        lookups = 0
        OrganiserCredentials.resetForTesting(lookup: { [unowned self] _ in lookups += 1; return (status, token) })
    }

    func testAKeychainThatRefusesIsNotAskedAgainUntilRetry() {
        stubKeychain(errSecInteractionNotAllowed)
        XCTAssertThrowsError(try OrganiserCredentials.read("https://a.example"))
        XCTAssertThrowsError(try OrganiserCredentials.read("https://a.example"))
        XCTAssertEqual(lookups, 1, "the second poll must reuse the failure, not re-prompt")
        OrganiserCredentials.retry()
        XCTAssertThrowsError(try OrganiserCredentials.read("https://a.example"))
        XCTAssertEqual(lookups, 2)
    }

    func testAKeyReadOnceIsReusedWithoutAskingAgain() throws {
        stubKeychain(errSecSuccess, "token-value")
        XCTAssertEqual(try OrganiserCredentials.read("https://a.example"), "token-value")
        XCTAssertEqual(try OrganiserCredentials.read("https://a.example"), "token-value")
        XCTAssertEqual(lookups, 1)
    }

    func testAMissingKeyIsReportedAsNoneAndRemembered() throws {
        stubKeychain(errSecItemNotFound)
        XCTAssertNil(try OrganiserCredentials.read("https://a.example"))
        XCTAssertNil(try OrganiserCredentials.read("https://a.example"))
        XCTAssertEqual(lookups, 1)
    }
}
