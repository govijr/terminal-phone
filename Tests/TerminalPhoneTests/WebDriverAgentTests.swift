import XCTest
import Foundation
import TerminalPhoneCore
@testable import TerminalPhone

private final class WDAProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> [String: Any])!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let reply = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: reply))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class WebDriverAgentTests: XCTestCase {
    private func agent(_ handler: @escaping (URLRequest) throws -> [String: Any]) -> WebDriverAgent {
        WDAProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [WDAProtocol.self]
        return WebDriverAgent(host: "127.0.0.1", session: URLSession(configuration: configuration))
    }

    func testExistingSessionFromStatusIsReusedWithoutReplacingViewerSession() async throws {
        var paths: [String] = []
        let agent = agent { request in
            let path = request.url!.path; paths.append(path)
            return ["sessionId": "existing", "value": path == "/status" ? ["ready": true] : NSNull()]
        }
        try await agent.tap(10, 20)
        XCTAssertEqual(paths, ["/status", "/session/existing/wda/tap"])
    }

    func testRepeatedInvalidSessionIsRetriedOnlyOnce() async {
        var taps = 0
        let agent = agent { request in
            if request.url!.path == "/status" { return ["sessionId": "existing", "value": ["ready": true]] }
            taps += 1
            return ["value": ["error": "invalid session id", "message": "Session ended"]]
        }
        do { try await agent.tap(10, 20); XCTFail("Expected invalid session") } catch {}
        XCTAssertEqual(taps, 2)
    }

    func testLostInputResponseIsNeverRetried() async {
        var taps = 0
        let agent = agent { request in
            if request.url!.path == "/status" { return ["sessionId": "existing", "value": ["ready": true]] }
            taps += 1
            throw URLError(.timedOut)
        }
        do { try await agent.tap(10, 20); XCTFail("Expected timeout") } catch {}
        XCTAssertEqual(taps, 1)
    }

    func testNativeFillResolvesBoundsThenClearsAndSetsValue() async throws {
        var paths: [String] = []
        let agent = agent { request in
            let path = request.url!.path; paths.append(path)
            let value: Any
            if path == "/status" { value = ["ready": true] }
            else if path.hasSuffix("/elements") { value = [["element-6066-11e4-a52e-4f735466cecf": "field"]] }
            else if path.hasSuffix("/rect") { value = ["x": 20, "y": 40, "width": 100, "height": 44] }
            else { value = NSNull() }
            return ["sessionId": "existing", "value": value]
        }
        let target = PhoneElement(role: "textfield", identifier: "message", bounds: PhoneBounds(x: 20, y: 40, width: 100, height: 44))
        try await agent.fillElement(target, text: "hello")
        XCTAssertEqual(paths, ["/status", "/session/existing/elements", "/session/existing/element/field/rect",
                               "/session/existing/element/field/clear", "/session/existing/element/field/value"])
    }

    func testMovedNativeTargetIsRejectedBeforeClick() async {
        var clicked = false
        let agent = agent { request in
            let path = request.url!.path
            if path == "/status" { return ["sessionId": "existing", "value": ["ready": true]] }
            if path.hasSuffix("/elements") { return ["value": [["ELEMENT": "button"]]] }
            if path.hasSuffix("/rect") { return ["value": ["x": 20, "y": 400, "width": 100, "height": 44]] }
            clicked = true; return ["value": NSNull()]
        }
        let target = PhoneElement(role: "button", identifier: "continue", bounds: PhoneBounds(x: 20, y: 40, width: 100, height: 44))
        do { try await agent.tapElement(target); XCTFail("Expected stale reference") }
        catch { XCTAssertEqual((error as? AgentError)?.code, .staleReference) }
        XCTAssertFalse(clicked)
    }
}
