import XCTest
@testable import TerminalPhone

final class PhoneSetupTests: XCTestCase {
    func testSelectedXcodeComesBeforeTheDefaultXcodeBundle() {
        let candidates = PhoneSetup.developerDirectoryCandidates(
            existing: nil, configured: nil, selected: "/Applications/Xcode-27.1.app/Contents/Developer",
            applications: ["Xcode.app", "Xcode-27.1.app", "Safari.app"])
        XCTAssertEqual(candidates, [
            "/Applications/Xcode-27.1.app/Contents/Developer",
            "/Applications/Xcode.app/Contents/Developer",
        ])
    }
    func testExplicitAndSavedDirectoriesStillWin() {
        let candidates = PhoneSetup.developerDirectoryCandidates(
            existing: "/opt/Xcode-beta.app/Contents/Developer", configured: "/Applications/Xcode-27.app/Contents/Developer",
            selected: "/Applications/Xcode-27.1.app/Contents/Developer", applications: ["Xcode-27.app"])
        XCTAssertEqual(candidates.prefix(3), [
            "/opt/Xcode-beta.app/Contents/Developer",
            "/Applications/Xcode-27.app/Contents/Developer",
            "/Applications/Xcode-27.1.app/Contents/Developer",
        ])
        XCTAssertEqual(candidates.count, 4)
    }
    func testWithoutASelectionTheOldOrderIsKept() {
        let candidates = PhoneSetup.developerDirectoryCandidates(existing: nil, configured: nil, selected: nil,
                                                                 applications: ["Xcode-26.app", "Xcode-27.app"])
        XCTAssertEqual(candidates, [
            "/Applications/Xcode.app/Contents/Developer",
            "/Applications/Xcode-27.app/Contents/Developer",
            "/Applications/Xcode-26.app/Contents/Developer",
        ])
    }
}
