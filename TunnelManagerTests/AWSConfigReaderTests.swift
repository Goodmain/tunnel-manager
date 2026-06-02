import XCTest
@testable import TunnelManager

final class AWSConfigReaderTests: XCTestCase {
    func testMixedSectionsParsedAndSorted() {
        let config = """
        [default]
        region = us-east-1
        [profile staging]
        region = us-west-2
        [profile prod]
        [sso-session my-sso]
        sso_region = us-east-1
        [services my-svc]
        [profile staging]
        """
        let parsed = AWSConfigReader.parse(config)
        // parse() preserves file order + dedupes; sorting matches profiles().
        let sorted = parsed.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        XCTAssertEqual(sorted, ["default", "prod", "staging"])
    }

    func testEmptyInput() {
        XCTAssertEqual(AWSConfigReader.parse(""), [])
    }

    func testSkipsNonProfileSections() {
        let config = """
        [sso-session x]
        [services y]
        [random]
        """
        XCTAssertEqual(AWSConfigReader.parse(config), [])
    }

    func testDedupesPreservingFirstOrder() {
        let config = """
        [profile a]
        [profile b]
        [profile a]
        """
        XCTAssertEqual(AWSConfigReader.parse(config), ["a", "b"])
    }
}
