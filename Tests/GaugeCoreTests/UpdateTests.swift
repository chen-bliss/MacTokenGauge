import XCTest
@testable import GaugeCore

final class UpdateTests: XCTestCase {
    func testSemanticVersionOrderingAndReleaseLinkValidation() {
        let response = Data(#"{"tag_name":"v1.10.0","html_url":"https://github.com/chen-bliss/MacTokenGauge/releases/tag/v1.10.0","draft":false,"prerelease":false}"#.utf8)
        XCTAssertEqual(UpdateChecker.parse(response, currentVersion: "1.9.9"), .available(version: "v1.10.0", url: URL(string: "https://github.com/chen-bliss/MacTokenGauge/releases/tag/v1.10.0")!))
        XCTAssertEqual(UpdateChecker.parse(response, currentVersion: "1.10.0"), .upToDate)
        XCTAssertEqual(UpdateChecker.parse(response, currentVersion: "2.0.0"), .upToDate)
        let untrusted = Data(#"{"tag_name":"v1.10.0","html_url":"https://example.com/download"}"#.utf8)
        XCTAssertEqual(UpdateChecker.parse(untrusted, currentVersion: "1.0.0"), .failed)
        let prerelease = Data(#"{"tag_name":"v2.0.0","html_url":"https://github.com/chen-bliss/MacTokenGauge/releases/tag/v2.0.0","prerelease":true}"#.utf8)
        XCTAssertEqual(UpdateChecker.parse(prerelease, currentVersion: "1.0.0"), .failed)
    }
}
