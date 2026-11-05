import XCTest
import TerminalPhoneCore

final class FrameFinishTests: XCTestCase {
    func testNamesAcceptRawAndDisplayNames() {
        XCTAssertEqual(FrameFinish(named: "orange"), .orange)
        XCTAssertEqual(FrameFinish(named: "Cosmic Orange"), .orange)
        XCTAssertEqual(FrameFinish(named: "space-black"), .black)
        XCTAssertEqual(FrameFinish(named: "DEEP BLUE"), .blue)
        XCTAssertNil(FrameFinish(named: "chartreuse"))
        XCTAssertTrue(FrameFinish.names.hasPrefix("graphite, black, silver"))
    }

    func testCyclingVisitsEveryFinishAndWraps() {
        var seen: [FrameFinish] = [], finish = FrameFinish.graphite
        for _ in FrameFinish.allCases { seen.append(finish); finish = finish.next }
        XCTAssertEqual(seen, FrameFinish.allCases)
        XCTAssertEqual(finish, .graphite)
    }

    func testEachFinishHasDistinctColours() {
        XCTAssertEqual(Set(FrameFinish.allCases.map(\.band)).count, FrameFinish.allCases.count)
        XCTAssertNotEqual(DeviceFrame(screenWidth: 402, screenHeight: 874, finish: .red), DeviceFrame(screenWidth: 402, screenHeight: 874, finish: .blue))
    }

    func testFrameIsRememberedPerPhone() throws {
        let store = PhoneStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("tp-frame-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: store.root) }
        var config = try PhoneConfiguration.load(store: store)
        XCTAssertNil(config.frame(for: "work"))
        config.preferredPhone = "work"
        config.setFrame(.orange, for: "work"); config.setFrame(.silver, for: "demo")
        try config.save(store: store)
        let loaded = try PhoneConfiguration.load(store: store)
        XCTAssertEqual(loaded.frame(for: "work"), .orange)
        XCTAssertEqual(loaded.frame(for: "demo"), .silver)
        XCTAssertEqual(loaded.preferredPhone, "work")
        // Configurations written before frames existed still load.
        try Data(#"{"preferredPhone":"default"}"#.utf8).write(to: store.root.appendingPathComponent("configuration.json"))
        XCTAssertNil(try PhoneConfiguration.load(store: store).frame(for: "default"))
    }
}
