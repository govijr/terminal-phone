import XCTest
import Foundation
import TerminalMacCore
@testable import TerminalPhoneCore

@MainActor
private final class TestPhoneBackend: PhoneBackend {
    let phone = try! Phone(name: "agent-test", udid: "A1122334-5566-7788-9900-AABBCCDDEEFF", deviceType: "test", runtime: "test")
    var scenes: [PhoneScene]
    var actions: [(PhoneAction, PhoneElement?)] = []
    var captureCount = 0
    var captureFailureAt: Int?
    var performFailure = false
    var delay: UInt64 = 0
    var foregroundApp = true
    var inputDelay: UInt64 = 0
    init(_ scenes: [PhoneScene]) { self.scenes = scenes }
    func capabilities(inputAllowed: Bool) -> PhoneCapabilities {
        PhoneCapabilities(backend: "test", inputAllowed: inputAllowed, foregroundApp: foregroundApp, elementActions: "test", actions: PhoneAction.Kind.allCases)
    }
    func capture() async throws -> PhoneCapture {
        captureCount += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if captureCount == captureFailureAt { throw AgentError(.disconnected, "Disconnected during capture.") }
        let scene = scenes.count > 1 ? scenes.removeFirst() : scenes[0]
        return PhoneCapture(scene: scene, png: Data([137, 80, 78, 71]))
    }
    func perform(_ action: PhoneAction, target: PhoneElement?) async throws {
        if inputDelay > 0 { try await Task.sleep(nanoseconds: inputDelay) }
        actions.append((action, target))
        if performFailure { throw AgentError(.disconnected, "Reply lost after input.") }
    }
    func close() {}
}

final class AgentSessionTests: XCTestCase {
    private let bounds = PhoneBounds(x: 20, y: 40, width: 100, height: 44)
    private func scene(label: String = "Continue", identifier: String = "continue", enabled: Bool = true, orientation: String = "portrait") -> PhoneScene {
        PhoneScene(width: 402, height: 874, scale: 3, orientation: orientation,
                   app: PhoneAppContext(bundleId: "dev.test.app", name: "Test"),
                   elements: [PhoneElement(role: "button", identifier: identifier, label: label, bounds: bounds, enabled: enabled)])
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("phone-agent-tests-\(UUID().uuidString)") }
    @MainActor private func session(_ backend: TestPhoneBackend, root: URL, allowed: Bool = true, control: @escaping () throws -> AnyObject = { NSObject() }) -> PhoneAgentSession {
        PhoneAgentSession(backend: backend, artifacts: root, inputAllowed: { allowed }, acquireControl: control)
    }

    @MainActor func testObservationAndRefActionShareGeometryAndPersistImage() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let backend = TestPhoneBackend([scene()]), session = session(backend, root: root)
        let observed = await session.handle(PhoneAgentRequest(operation: .observe))
        let observation = try XCTUnwrap(observed.observation)
        XCTAssertEqual(observation.width, 402); XCTAssertEqual(observation.coordinateSpace, "display-points")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(observation.screenshot)))
        let action = PhoneAction(kind: .tap, target: ElementSelector(ref: observation.elements[0].ref))
        let result = await session.handle(PhoneAgentRequest(operation: .act, action: action, observeAfter: true))
        XCTAssertTrue(result.ok); XCTAssertEqual(backend.actions.count, 1)
        XCTAssertEqual(backend.actions[0].1?.identifier, "continue")
        XCTAssertEqual(result.action?.outcome, "input-delivered"); XCTAssertEqual(result.action?.verified, false)
        XCTAssertNotEqual(result.observation?.id, observation.id)
    }

    @MainActor func testChangedUIAndRotationInvalidateReferencesBeforeInput() async throws {
        for changed in [scene(label: "Delete"), scene(orientation: "landscape")] {
            let backend = TestPhoneBackend([scene(), changed]), session = session(backend, root: directory())
            let observed = await session.handle(PhoneAgentRequest(operation: .observe, includeImage: false))
            let ref = try XCTUnwrap(observed.observation?.elements.first?.ref)
            let result = await session.handle(PhoneAgentRequest(operation: .act, action: PhoneAction(kind: .tap, target: ElementSelector(ref: ref))))
            XCTAssertEqual(result.error?.code, .staleReference); XCTAssertTrue(backend.actions.isEmpty)
        }
    }

    @MainActor func testNewObservationInvalidatesOldRefEvenIfUIIsUnchanged() async throws {
        let backend = TestPhoneBackend([scene()]), session = session(backend, root: directory())
        let first = await session.handle(PhoneAgentRequest(operation: .observe, includeImage: false))
        _ = await session.handle(PhoneAgentRequest(operation: .observe, includeImage: false))
        let result = await session.handle(PhoneAgentRequest(operation: .act, action: PhoneAction(kind: .tap, target: ElementSelector(ref: first.observation!.elements[0].ref))))
        XCTAssertEqual(result.error?.code, .staleReference); XCTAssertTrue(backend.actions.isEmpty)
    }

    @MainActor func testAmbiguousAndDisabledTargetsNeverReceiveInput() async {
        let base = scene()
        let duplicate = PhoneScene(width: base.width, height: base.height, scale: base.scale, orientation: base.orientation, app: base.app, elements: base.elements + base.elements)
        for (value, expected) in [(duplicate, AgentError.Code.ambiguousTarget), (scene(enabled: false), .targetDisabled)] {
            let backend = TestPhoneBackend([value]), session = session(backend, root: directory())
            let reply = await session.handle(PhoneAgentRequest(operation: .act, action: PhoneAction(kind: .tap, target: ElementSelector(identifier: "continue"))))
            XCTAssertEqual(reply.error?.code, expected); XCTAssertTrue(backend.actions.isEmpty)
        }
    }

    @MainActor func testInputGrantAndControllerAreEnforcedWhileReadsStayAvailable() async {
        let backend = TestPhoneBackend([scene()]), root = directory()
        var acquisitions = 0
        let session = session(backend, root: root, allowed: false, control: { acquisitions += 1; return NSObject() })
        let observed = await session.handle(PhoneAgentRequest(operation: .observe, includeImage: false))
        let reply = await session.handle(PhoneAgentRequest(operation: .act, action: PhoneAction(kind: .press, text: "HOME")))
        XCTAssertTrue(observed.ok); XCTAssertEqual(reply.error?.code, .inputDisabled); XCTAssertEqual(acquisitions, 0)
        let busy = self.session(backend, root: root, control: { throw AgentError(.controllerBusy, "Busy") })
        let result = await busy.handle(PhoneAgentRequest(operation: .act, action: PhoneAction(kind: .press, text: "HOME")))
        XCTAssertEqual(result.error?.code, .controllerBusy); XCTAssertTrue(backend.actions.isEmpty)
    }

    @MainActor func testDuplicateRequestIsNotReplayedAndConflictIsRejected() async {
        let backend = TestPhoneBackend([scene()]), session = session(backend, root: directory())
        let request = PhoneAgentRequest(operation: .act, id: "same", action: PhoneAction(kind: .tap, coordinates: [50, 60]))
        let first = await session.handle(request), second = await session.handle(request)
        XCTAssertTrue(first.ok && second.ok); XCTAssertEqual(backend.actions.count, 1)
        let conflict = await session.handle(PhoneAgentRequest(operation: .act, id: "same", action: PhoneAction(kind: .tap, coordinates: [80, 90])))
        XCTAssertEqual(conflict.error?.code, .requestConflict); XCTAssertEqual(backend.actions.count, 1)
    }

    @MainActor func testLostInputReplyStaysUnknownAndIsNotRetried() async {
        let backend = TestPhoneBackend([scene()]); backend.performFailure = true
        let session = session(backend, root: directory())
        let request = PhoneAgentRequest(operation: .act, id: "uncertain", action: PhoneAction(kind: .press, text: "HOME"))
        let reply = await session.handle(request)
        _ = await session.handle(request)
        XCTAssertEqual(reply.error?.code, .actionOutcomeUnknown); XCTAssertEqual(reply.action?.outcome, "unknown")
        XCTAssertEqual(backend.actions.count, 1)
    }

    @MainActor func testWaitVerifiesStateAndTimeoutDoesNotReplayDeliveredInput() async {
        for matched in [true, false] {
            let backend = TestPhoneBackend([scene(), scene(label: matched ? "Welcome" : "Continue")])
            let session = session(backend, root: directory())
            let reply = await session.handle(PhoneAgentRequest(operation: .act, action: PhoneAction(kind: .tap, coordinates: [50, 60]),
                                                              condition: PhoneWaitCondition(text: "Welcome"), timeout: 0, includeImage: false))
            XCTAssertEqual(reply.ok, matched); XCTAssertEqual(reply.action?.verified, matched)
            XCTAssertEqual(reply.action?.outcome, "input-delivered"); XCTAssertNotNil(reply.observation)
            XCTAssertEqual(backend.actions.count, 1)
            if !matched { XCTAssertEqual(reply.error?.code, .waitTimeout) }
        }
    }

    @MainActor func testObservationFailureAfterInputRetainsDeliveredReceipt() async {
        let backend = TestPhoneBackend([scene()]); backend.captureFailureAt = 2
        let session = session(backend, root: directory())
        let reply = await session.handle(PhoneAgentRequest(operation: .act, action: PhoneAction(kind: .tap, coordinates: [50, 60]), observeAfter: true))
        XCTAssertEqual(reply.error?.code, .observationFailed); XCTAssertEqual(reply.action?.outcome, "input-delivered")
        XCTAssertEqual(backend.actions.count, 1)
    }

    @MainActor func testReleaseDropsControlAndInvalidatesOldReferences() async {
        let backend = TestPhoneBackend([scene()]); var acquisitions = 0
        let session = session(backend, root: directory(), control: { acquisitions += 1; return NSObject() })
        let action = PhoneAgentRequest(operation: .act, action: PhoneAction(kind: .press, text: "HOME"))
        _ = await session.handle(action)
        XCTAssertTrue(session.info.controlsInput)
        _ = await session.handle(PhoneAgentRequest(operation: .release))
        XCTAssertFalse(session.info.controlsInput)
        _ = await session.handle(PhoneAgentRequest(operation: .act, action: PhoneAction(kind: .press, text: "HOME")))
        XCTAssertEqual(acquisitions, 2)
    }

    @MainActor func testWrongSessionAndUnavailableAppContextFailBeforeInput() async {
        let backend = TestPhoneBackend([scene()]); backend.foregroundApp = false
        let session = session(backend, root: directory())
        let reply = await session.handle(PhoneAgentRequest(operation: .act, action: PhoneAction(kind: .press, text: "HOME"), sessionId: "ended"))
        XCTAssertEqual(reply.error?.code, .staleReference)
        let wait = await session.handle(PhoneAgentRequest(operation: .wait, condition: PhoneWaitCondition(app: "dev.test.app"), timeout: 0))
        XCTAssertEqual(wait.error?.code, .unsupported); XCTAssertEqual(backend.captureCount, 0)
    }

    @MainActor func testConcurrentDirectCallsCannotInterleaveBackendOperations() async throws {
        let backend = TestPhoneBackend([scene()]); backend.delay = 50_000_000
        let session = session(backend, root: directory())
        let first = Task { await session.handle(PhoneAgentRequest(operation: .observe, includeImage: false)) }
        try await Task.sleep(nanoseconds: 5_000_000)
        let second = await session.handle(PhoneAgentRequest(operation: .observe, includeImage: false))
        XCTAssertEqual(second.error?.code, .controllerBusy)
        let initial = await first.value; XCTAssertTrue(initial.ok)
    }

    @MainActor func testCancellationDuringInspectionPreventsInputDispatch() async throws {
        let backend = TestPhoneBackend([scene()]); backend.delay = 50_000_000
        let session = session(backend, root: directory())
        var cancelled = false
        let task = Task { await session.handle(PhoneAgentRequest(operation: .act, action: PhoneAction(kind: .tap, coordinates: [50, 60])), isCancelled: { cancelled }) }
        try await Task.sleep(nanoseconds: 5_000_000)
        cancelled = true
        let reply = await task.value
        XCTAssertEqual(reply.error?.code, .cancelled)
        XCTAssertTrue(backend.actions.isEmpty)
    }

    @MainActor func testViewerInputBypassesInspectionAndCancelsAgentWait() async throws {
        let backend = TestPhoneBackend([scene()]); backend.delay = 100_000_000
        let session = session(backend, root: directory())
        let waiting = Task { await session.handle(PhoneAgentRequest(operation: .wait, condition: PhoneWaitCondition(text: "never"), timeout: 10, includeImage: false)) }
        try await Task.sleep(nanoseconds: 10_000_000)
        let started = Date()
        let input = await session.handle(PhoneAgentRequest(operation: .input, action: PhoneAction(kind: .tap, coordinates: [30, 40]), includeImage: false))
        XCTAssertTrue(input.ok); XCTAssertEqual(input.action?.outcome, "input-delivered")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.08)
        XCTAssertEqual(backend.actions.count, 1); XCTAssertEqual(backend.captureCount, 1)
        let cancelled = await waiting.value
        XCTAssertEqual(cancelled.error?.code, .cancelled)
        let agent = await session.handle(PhoneAgentRequest(operation: .act, action: PhoneAction(kind: .tap, coordinates: [50, 60])))
        XCTAssertEqual(agent.error?.code, .controllerBusy)
    }

    @MainActor func testViewerInputStillEnforcesPhysicalDeviceGrantAndDeduplicates() async {
        let backend = TestPhoneBackend([scene()])
        let denied = session(backend, root: directory(), allowed: false)
        let request = PhoneAgentRequest(operation: .input, id: "human-event", action: PhoneAction(kind: .press, text: "HOME"), includeImage: false)
        let failed = await denied.handle(request)
        XCTAssertEqual(failed.error?.code, .inputDisabled); XCTAssertTrue(backend.actions.isEmpty)
        let allowed = session(backend, root: directory())
        let first = await allowed.handle(request), duplicate = await allowed.handle(request)
        XCTAssertTrue(first.ok && duplicate.ok); XCTAssertEqual(backend.actions.count, 1)
        XCTAssertEqual(backend.captureCount, 0)
    }

    @MainActor func testReleaseKeepsOwnershipUntilNativeInputFinishes() async throws {
        let backend = TestPhoneBackend([scene()]); backend.inputDelay = 70_000_000
        let session = session(backend, root: directory())
        let input = Task { await session.handle(PhoneAgentRequest(operation: .input, action: PhoneAction(kind: .press, text: "HOME"), includeImage: false)) }
        try await Task.sleep(nanoseconds: 10_000_000)
        var released = false
        let release = Task { let reply = await session.handle(PhoneAgentRequest(operation: .release)); released = true; return reply }
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertFalse(released); XCTAssertTrue(session.info.controlsInput)
        let inputResult = await input.value, releaseResult = await release.value
        XCTAssertTrue(inputResult.ok && releaseResult.ok)
        XCTAssertFalse(session.info.controlsInput); XCTAssertEqual(backend.actions.count, 1)
    }

    func testNormalizerRedactsSecureValuesAndRejectsOffscreenElements() throws {
        let tree: [[String: Any]] = [
            ["type": "XCUIElementTypeSecureTextField", "rawIdentifier": "password", "value": "secret",
             "rect": ["x": 10, "y": 20, "width": 150, "height": 44]],
            ["type": "Button", "AXLabel": "Hidden", "frame": ["x": 500, "y": 20, "width": 100, "height": 44]],
            ["type": "Button", "AXLabel": "Hidden WDA", "isVisible": "0", "rect": ["x": 20, "y": 100, "width": 100, "height": 44]],
            ["type": "Button", "AXLabel": "Disabled", "isEnabled": "0", "frame": ["x": 20, "y": 100, "width": 100, "height": 44]]
        ]
        let result = PhoneAccessibility.elements(from: tree, width: 402, height: 874)
        XCTAssertEqual(result.count, 2); XCTAssertEqual(result[0].role, "textfield")
        XCTAssertTrue(result[0].secure); XCTAssertNil(result[0].value); XCTAssertFalse(result[1].enabled)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("secret"))
    }

    func testActionValidationRejectsAmbiguousOrMalformedRequests() throws {
        XCTAssertThrowsError(try PhoneAction(kind: .tap, target: ElementSelector(ref: "ref", identifier: "id")).validate())
        XCTAssertThrowsError(try PhoneAction(kind: .tap, coordinates: [1, 2, 3]).validate())
        XCTAssertThrowsError(try PhoneAction(kind: .swipe, coordinates: [1, 2, 3, 4], duration: .nan).validate())
        XCTAssertThrowsError(try PhoneAction(kind: .type, text: "a\0b").validate())
        XCTAssertThrowsError(try PhoneWaitCondition().validate())
        XCTAssertNoThrow(try PhoneAction(kind: .fill, target: ElementSelector(identifier: "field"), text: "").validate())
        let condition = try JSONDecoder().decode(PhoneWaitCondition.self, from: Data(#"{"text":"Welcome"}"#.utf8))
        XCTAssertFalse(condition.absent)
    }

    func testPrivateSocketRoundTripAndFrameLimit() async throws {
        let root = URL(fileURLWithPath: "/tmp/tpa-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("s.sock").path
        let listener = try PhoneAgentSocket.listen(path)
        let payload = Data(repeating: 97, count: 256 * 1024)
        let server = Task.detached {
            let connection = try XCTUnwrap(listener.accept(timeout: 3))
            let data = try connection.readPacket(timeout: 3)
            try connection.writePacket(data)
            return data.count
        }
        let client = try PhoneAgentSocket.connect(path)
        try client.writePacket(payload)
        XCTAssertEqual(try client.readPacket(timeout: 3), payload)
        let size = try await server.value; XCTAssertEqual(size, payload.count)
        XCTAssertThrowsError(try client.writePacket(Data(count: PhoneAgentSocket.maxPacket + 1)))
    }

    @MainActor func testScreenshotRetentionIsBoundedAcrossSessionRestarts() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let backend = TestPhoneBackend([scene()]), first = session(backend, root: root)
        for _ in 0..<17 { _ = await first.handle(PhoneAgentRequest(operation: .observe)) }
        first.close()
        let second = session(backend, root: root)
        let reply = await second.handle(PhoneAgentRequest(operation: .observe))
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 16)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reply.observation!.screenshot!))
    }
}
