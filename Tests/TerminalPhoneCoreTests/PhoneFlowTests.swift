import XCTest
@testable import TerminalPhoneCore

final class PhoneFlowTests: XCTestCase {
    func testParsesEveryStepKind() throws {
        let flow = try PhoneFlow.parse("""
        # A comment line
        - launch: com.example.app
        - tap: "Sign in"            # trailing comment
        - tap: Sign up
        - tap: [120, 480]
        - tap: {id: submit}
        - tap: {x: 10, y: 20}
        - fill: {id: email, text: "me@example.com"}
        - type: 'it''s'
        - press: Return
        - swipe: [200, 600, 200, 100]
        - swipe: {from: [1, 2], to: [3, 4], duration: 0.5}
        - scroll: down
        - scroll: {direction: up, id: list}
        - expect: "Welcome #1"
        - expect-not: {text: Error, timeout: 3}
        - wait: 1.5
        - screenshot: shots/home.png
        - open: "myapp://route?x=1"
        """)
        XCTAssertEqual(flow.steps.count, 18)
        XCTAssertEqual(flow.steps[0].line, 2)
        XCTAssertEqual(flow.steps[0].kind, .act(PhoneAction(kind: .launch, text: "com.example.app")))
        XCTAssertEqual(flow.steps[1].kind, .tapText("Sign in"))
        XCTAssertEqual(flow.steps[2].kind, .tapText("Sign up"))
        XCTAssertEqual(flow.steps[3].kind, .act(PhoneAction(kind: .tap, coordinates: [120, 480])))
        XCTAssertEqual(flow.steps[4].kind, .act(PhoneAction(kind: .tap, target: ElementSelector(identifier: "submit"))))
        XCTAssertEqual(flow.steps[5].kind, .act(PhoneAction(kind: .tap, coordinates: [10, 20])))
        XCTAssertEqual(flow.steps[6].kind, .act(PhoneAction(kind: .fill, target: ElementSelector(identifier: "email"), text: "me@example.com")))
        XCTAssertEqual(flow.steps[7].kind, .act(PhoneAction(kind: .type, text: "it's")))
        XCTAssertEqual(flow.steps[8].kind, .act(PhoneAction(kind: .press, text: "return")))
        XCTAssertEqual(flow.steps[10].kind, .act(PhoneAction(kind: .swipe, coordinates: [1, 2, 3, 4], duration: 0.5)))
        XCTAssertEqual(flow.steps[12].kind, .act(PhoneAction(kind: .scroll, target: ElementSelector(identifier: "list"), direction: "up")))
        XCTAssertEqual(flow.steps[13].kind, .expect(PhoneWaitCondition(text: "Welcome #1"), timeout: nil))
        XCTAssertEqual(flow.steps[14].kind, .expect(PhoneWaitCondition(text: "Error", absent: true), timeout: 3))
        XCTAssertEqual(flow.steps[15].kind, .pause(1.5))
        XCTAssertEqual(flow.steps[16].kind, .screenshot("shots/home.png"))
        XCTAssertEqual(flow.steps[17].kind, .act(PhoneAction(kind: .open, text: "myapp://route?x=1")))
    }

    func testReportsTheFailingLine() {
        let cases = ["- tapp: x", "tap: x", "- tap: [1, 2", "- fill: {id: a}", "- swipe: [1, 2, 3]", "- wait: forever", "- tap: \"open", "- tap: {id: a, idd: b}"]
        for text in cases {
            XCTAssertThrowsError(try PhoneFlow.parse("- press: home\n" + text), text) { error in
                XCTAssertEqual((error as? PhoneFlowError)?.line, 2, text)
            }
        }
    }

    func testRendersRecordedInputAsAReplayableFlow() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let button = PhoneElement(role: "button", identifier: "submit", label: "Submit", bounds: PhoneBounds(x: 0, y: 0, width: 10, height: 10))
        let password = PhoneElement(role: "textfield", identifier: "password", bounds: PhoneBounds(x: 0, y: 0, width: 10, height: 10), secure: true)
        let entries = [
            PhoneActionLogEntry(at: start, source: "viewer", action: PhoneAction(kind: .tap, coordinates: [10, 20]), target: nil, outcome: "delivered", error: nil, requestId: "1"),
            PhoneActionLogEntry(at: start.addingTimeInterval(0.3), source: "viewer", action: PhoneAction(kind: .type, text: "say \"hi\"\n"), target: nil, outcome: "delivered", error: nil, requestId: "2"),
            PhoneActionLogEntry(at: start.addingTimeInterval(2.5), source: "agent", action: PhoneAction(kind: .tap, target: ElementSelector(ref: "s1:e1")), target: button, outcome: "delivered", error: nil, requestId: "3"),
            PhoneActionLogEntry(at: start.addingTimeInterval(3), source: "agent", action: PhoneAction(kind: .fill, target: ElementSelector(identifier: "password"), text: "secret"), target: password, outcome: "delivered", error: nil, requestId: "4"),
            PhoneActionLogEntry(at: start.addingTimeInterval(3.1), source: "agent", action: PhoneAction(kind: .tap, coordinates: [1, 1]), target: nil, outcome: "unknown", error: "timeout", requestId: "5"),
            PhoneActionLogEntry(at: start.addingTimeInterval(3.2), source: "viewer", action: PhoneAction(kind: .swipe, coordinates: [1, 2, 3, 4], duration: 0.3), target: nil, outcome: "delivered", error: nil, requestId: "6"),
        ]
        XCTAssertEqual(entries[3].action.text, PhoneActionLog.redacted, "secure text never reaches the log")
        let text = PhoneFlow.render(entries, header: "Recorded")
        XCTAssertEqual(text, """
        # Recorded
        - tap: [10, 20]
        - type: "say \\"hi\\"\\n"
        - wait: 2.2
        - tap: {id: "submit"}
        - fill: {id: "password", text: ""}  # secure field: its text was not recorded
        - swipe: [1, 2, 3, 4]

        """)
        let flow = try PhoneFlow.parse(text)
        XCTAssertEqual(flow.steps.count, 6)
        XCTAssertEqual(flow.steps[1].kind, .act(PhoneAction(kind: .type, text: "say \"hi\"\n")))
    }

    func testActionLogAppendsReadsAndRotates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = PhoneActionLog.url(in: directory)
        let old = Date(timeIntervalSinceNow: -60)
        try PhoneActionLog.append(PhoneActionLogEntry(at: old, source: "viewer", action: PhoneAction(kind: .press, text: "home"), target: nil, outcome: "delivered", error: nil, requestId: "a"), to: url)
        try PhoneActionLog.append(PhoneActionLogEntry(source: "agent", action: PhoneAction(kind: .tap, coordinates: [1, 2]), target: nil, outcome: "delivered", error: nil, requestId: "b"), to: url)
        XCTAssertEqual(PhoneActionLog.read(url).map(\.requestId), ["a", "b"])
        XCTAssertEqual(PhoneActionLog.read(url, since: Date(timeIntervalSinceNow: -30)).map(\.requestId), ["b"])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        // Past the size limit, the file moves aside and both halves stay readable.
        try Data(count: PhoneActionLog.maxBytes + 1).write(to: url)
        try PhoneActionLog.append(PhoneActionLogEntry(source: "agent", action: PhoneAction(kind: .press, text: "home"), target: nil, outcome: "delivered", error: nil, requestId: "c"), to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path))
        XCTAssertEqual(PhoneActionLog.read(url).map(\.requestId), ["c"])
        XCTAssertEqual(PhoneActionLog.describe(PhoneActionLog.read(url)[0]), "press “home”")
    }
}
