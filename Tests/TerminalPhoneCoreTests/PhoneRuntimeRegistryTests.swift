import XCTest
import TerminalPhoneCore

final class PhoneRuntimeRegistryTests: XCTestCase {
    func testPeerUnderPrivateMatchesTheResolvedExecutablePath() throws {
        // proc_pidpath reports /private/tmp/..., while URL.resolvingSymlinksInPath() drops /private.
        let file = URL(fileURLWithPath: "/tmp/terminal-phone-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: file) }
        let current = file.resolvingSymlinksInPath().path
        XCTAssertTrue(current.hasPrefix("/tmp/"))
        XCTAssertTrue(PhoneRuntimeRegistry.isVerified(peer: "/private" + current, current: current, known: []))
        XCTAssertTrue(PhoneRuntimeRegistry.isVerified(peer: "/private" + current, current: "/elsewhere/terminal-phone", known: [current]))
        XCTAssertFalse(PhoneRuntimeRegistry.isVerified(peer: "/private" + current, current: "/elsewhere/terminal-phone", known: []))
        XCTAssertFalse(PhoneRuntimeRegistry.isVerified(peer: "", current: current, known: [current]))
    }
}
