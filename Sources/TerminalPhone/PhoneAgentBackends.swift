import Foundation
import TerminalPhoneCore
import TerminalMacCore

@MainActor
enum PhoneAgentBackends {
    static func make(cli: PhoneCLI, phone: Phone) -> PhoneBackend {
        phone.isDevice ? DevicePhoneBackend(cli: cli, phone: phone) : SimulatorPhoneBackend(cli: cli, phone: phone)
    }

    static func validateApp(_ text: String, device: Bool) throws -> URL {
        let path = URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL
        let platform = device ? "iPhoneOS" : "iPhoneSimulator"
        guard path.pathExtension == "app", let plist = NSDictionary(contentsOf: path.appendingPathComponent("Info.plist")),
              let platforms = plist["CFBundleSupportedPlatforms"] as? [String], platforms.contains(platform) else {
            throw AgentError(.invalidRequest, "Install requires a \(device ? "device-built, signed" : "simulator-built") .app for \(platform).")
        }
        return path
    }
    static func validateBundle(_ value: String) throws {
        guard value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]+$", options: .regularExpression) != nil else { throw AgentError(.invalidRequest, "Expected an app bundle identifier.") }
    }
    static func validateURL(_ value: String) throws {
        guard let url = URL(string: value), url.scheme?.isEmpty == false, !value.hasPrefix("-") else { throw AgentError(.invalidRequest, "Expected an absolute URL including its scheme.") }
    }
    static func point(_ target: PhoneElement, scene: PhoneScene) -> [Int] {
        let b = target.bounds
        return [Int(((max(0, b.x) + min(Double(scene.width - 1), b.x + b.width)) / 2).rounded()),
                Int(((max(0, b.y) + min(Double(scene.height - 1), b.y + b.height)) / 2).rounded())]
    }
    static func swipe(_ action: PhoneAction, target: PhoneElement?, scene: PhoneScene) -> [Int] {
        if let coordinates = action.coordinates { return coordinates }
        let b = target?.bounds ?? PhoneBounds(x: 0, y: 0, width: Double(scene.width), height: Double(scene.height))
        let left = max(0, b.x), top = max(0, b.y)
        let width = min(Double(scene.width - 1), b.x + b.width) - left
        let height = min(Double(scene.height - 1), b.y + b.height) - top
        let x = left + width / 2, y = top + height / 2
        switch action.direction {
        case "down": return [Int(x), Int(top + height * 0.8), Int(x), Int(top + height * 0.2)]
        case "up": return [Int(x), Int(top + height * 0.2), Int(x), Int(top + height * 0.8)]
        case "right": return [Int(left + width * 0.8), Int(y), Int(left + width * 0.2), Int(y)]
        default: return [Int(left + width * 0.2), Int(y), Int(left + width * 0.8), Int(y)]
        }
    }
    static let keys = ["return": 40, "escape": 41, "backspace": 42, "tab": 43, "delete": 76, "right": 79, "left": 80, "down": 81, "up": 82]
}

@MainActor
final class SimulatorPhoneBackend: PhoneBackend {
    let phone: Phone
    private let cli: PhoneCLI
    private let connection: SimulatorAgentConnection
    private let inputConnection: SimulatorAgentConnection
    private var scene: PhoneScene?
    init(cli: PhoneCLI, phone: Phone) {
        self.cli = cli; self.phone = phone
        connection = SimulatorAgentConnection(cli: cli, phone: phone)
        inputConnection = SimulatorAgentConnection(cli: cli, phone: phone, logName: "agent-input.log")
    }
    func capabilities(inputAllowed: Bool) -> PhoneCapabilities {
        PhoneCapabilities(backend: "idb", inputAllowed: inputAllowed && cli.touchAvailable, foregroundApp: false,
                          elementActions: "fresh-accessibility-bounds", actions: cli.touchAvailable ? PhoneAction.Kind.allCases : [.install, .launch, .open])
    }
    func capture() async throws -> PhoneCapture {
        let started = Date()
        let (saved, catalog) = try await cli.phone(phone.name)
        guard saved.udid == phone.udid else { throw AgentError(.notReady, "The phone registration changed. Stop this session and reconnect.") }
        let payload = try await connection.call("capture")
        guard let encoded = payload["png"] as? String, let png = Data(base64Encoded: encoded), let tree = payload["tree"] else {
            throw AgentError(.observationFailed, "The simulator helper returned an incomplete observation.")
        }
        let frame = try cli.resized(png, scale: cli.screenScale(saved, catalog: catalog))
        let current = PhoneScene(width: frame.width, height: frame.height, scale: frame.scale,
                                 orientation: frame.height >= frame.width ? "portrait" : "landscape", app: PhoneAppContext(),
                                 elements: PhoneAccessibility.elements(from: tree, width: frame.width, height: frame.height))
        scene = current
        return PhoneCapture(scene: current, png: frame.png, startedAt: started, finishedAt: Date())
    }
    func perform(_ action: PhoneAction, target: PhoneElement?) async throws {
        if [.install, .launch, .open].contains(action.kind) {
            _ = try await cli.phone(phone.name)
            switch action.kind {
            case .install:
                let app = try PhoneAgentBackends.validateApp(action.text!, device: false)
                _ = try await cli.simctl(["install", phone.udid, app.path], timeout: 120)
            case .launch:
                try PhoneAgentBackends.validateBundle(action.text!)
                // Like a real iPhone's launch, start fresh so a rebuilt app actually runs.
                _ = try await cli.simctl(["launch", "--terminate-running-process", phone.udid, action.text!])
            default:
                try PhoneAgentBackends.validateURL(action.text!)
                _ = try await cli.simctl(["openurl", phone.udid, action.text!])
            }
            return
        }
        switch action.kind {
        case .tap:
            let point: [Int]
            if let target, let scene { point = PhoneAgentBackends.point(target, scene: scene) }
            else { point = action.coordinates! }
            _ = try await inputConnection.call("tap", values: point.map(String.init))
        case .fill:
            guard let target, let scene, ["textfield", "textview"].contains(target.role) else { throw AgentError(.unsupported, "Fill requires a text field or text view.") }
            _ = try await inputConnection.call("fill", values: PhoneAgentBackends.point(target, scene: scene).map(String.init), text: action.text!)
        case .type: _ = try await inputConnection.call("type", values: [action.text!])
        case .swipe:
            _ = try await inputConnection.call("swipe", values: action.coordinates!.map(String.init), duration: action.duration ?? 0.3)
        case .scroll:
            guard let scene else { throw AgentError(.notReady, "Observe the phone before scrolling.") }
            _ = try await inputConnection.call("swipe", values: PhoneAgentBackends.swipe(action, target: target, scene: scene).map(String.init), duration: action.duration ?? 0.3)
        case .press:
            let value = action.text!
            if let key = PhoneAgentBackends.keys[value.lowercased()] { _ = try await inputConnection.call("key", values: [String(key)]) }
            else {
                guard ["HOME", "LOCK", "SIRI"].contains(value.uppercased()) else { throw AgentError(.unsupported, "Unsupported simulator key or button: \(value).") }
                _ = try await inputConnection.call("button", values: [value.uppercased()])
            }
        case .install, .launch, .open: break
        }
    }
    func close() { connection.close(); inputConnection.close(); scene = nil }
}

@MainActor
final class DevicePhoneBackend: PhoneBackend {
    let phone: Phone
    private let cli: PhoneCLI
    private var agent: WebDriverAgent?
    private var scene: PhoneScene?
    init(cli: PhoneCLI, phone: Phone) { self.cli = cli; self.phone = phone }
    func capabilities(inputAllowed: Bool) -> PhoneCapabilities {
        PhoneCapabilities(backend: "webdriveragent", inputAllowed: inputAllowed, foregroundApp: true,
                          elementActions: "native-xctest-elements", actions: PhoneAction.Kind.allCases)
    }
    private func client() async throws -> WebDriverAgent {
        if let agent { return agent }
        let connected = try await PhoneDevices.connect(cli, phone, progress: false)
        agent = connected; return connected
    }
    func capture() async throws -> PhoneCapture {
        let started = Date()
        do {
            let agent = try await client()
            if (try await agent.call("GET", "/wda/locked") as? Bool) == true {
                throw AgentError(.deviceLocked, "The iPhone is locked.", recovery: "Ask the owner to unlock it, then observe again.")
            }
            let source = try await agent.call("GET", "/source?format=json&excluded_attributes=accessible,nativeAccessibilityElement,focused,nativeFrame,traits,minValue,maxValue,placeholderValue,frame", timeout: 45)
            let app = try await agent.call("GET", "/wda/activeAppInfo") as? [String: Any]
            let screen = try await agent.screen()
            let frame = try cli.resized(try await agent.screenshot(), scale: screen.scale)
            let orientation = try await agent.call("GET", "/orientation", inSession: true) as? String
            let current = PhoneScene(width: frame.width, height: frame.height, scale: frame.scale,
                                     orientation: orientation?.lowercased() ?? (frame.height >= frame.width ? "portrait" : "landscape"),
                                     app: PhoneAppContext(bundleId: app?["bundleId"] as? String, name: app?["name"] as? String),
                                     elements: PhoneAccessibility.elements(from: source, width: frame.width, height: frame.height))
            scene = current
            return PhoneCapture(scene: current, png: frame.png, startedAt: started, finishedAt: Date())
        } catch { agent = nil; PhoneDevices.forget(phone); throw AgentError.backend(error) }
    }
    func perform(_ action: PhoneAction, target: PhoneElement?) async throws {
        let current = try cli.store.load(phone.name)
        guard current.udid == phone.udid, current.acceptsInput else { throw AgentError(.inputDisabled, "The owner's input grant is no longer available.") }
        let agent = try await client()
        if (try await agent.call("GET", "/wda/locked") as? Bool) == true { throw AgentError(.deviceLocked, "The iPhone is locked.") }
        switch action.kind {
        case .tap:
            if let target { try await agent.tapElement(target) }
            else { try await agent.tap(action.coordinates![0], action.coordinates![1]) }
        case .fill:
            guard let target, ["textfield", "textview"].contains(target.role) else { throw AgentError(.unsupported, "Fill requires a text field or text view.") }
            try await agent.fillElement(target, text: action.text!)
        case .type: try await agent.type(action.text!)
        case .swipe:
            let points = action.coordinates!
            try await agent.swipe(points[0], points[1], points[2], points[3], duration: action.duration ?? 0.3)
        case .scroll:
            guard let scene else { throw AgentError(.notReady, "Observe the phone before sending input.") }
            let points = PhoneAgentBackends.swipe(action, target: target, scene: scene)
            try await agent.swipe(points[0], points[1], points[2], points[3], duration: action.duration ?? 0.3)
        case .press:
            if let key = WebDriverAgent.keys[action.text!.lowercased()] { try await agent.type(key) }
            else {
                guard ["HOME", "LOCK", "VOLUMEUP", "VOLUMEDOWN"].contains(action.text!.uppercased()) else { throw AgentError(.unsupported, "Unsupported iPhone key or button.") }
                try await agent.button(action.text!)
            }
        case .install:
            let app = try PhoneAgentBackends.validateApp(action.text!, device: true)
            _ = try await CommandRunner.checked(cli.xcrun, ["devicectl", "device", "install", "app", "--device", phone.udid, app.path], timeout: 300)
        case .launch:
            try PhoneAgentBackends.validateBundle(action.text!)
            _ = try await CommandRunner.checked(cli.xcrun, ["devicectl", "device", "process", "launch", "--device", phone.udid, "--terminate-existing", action.text!])
        case .open:
            try PhoneAgentBackends.validateURL(action.text!); try await agent.open(action.text!)
        }
    }
    func close() { agent = nil; scene = nil }
}

extension WebDriverAgent {
    private func elementID(_ element: PhoneElement) async throws -> String {
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'" }
        let using: String, value: String
        if let identifier = element.identifier { using = "accessibility id"; value = identifier }
        else if let label = element.label { using = "predicate string"; value = "label == " + quoted(label) }
        else { throw AgentError(.unsupported, "This element has no native locator. Use coordinates from a new observation.") }
        let matches = try await call("POST", "/elements", ["using": using, "value": value], inSession: true) as? [[String: Any]] ?? []
        guard matches.count <= 32 else { throw AgentError(.ambiguousTarget, "Too many native elements match this target.") }
        var ids: [String] = []
        for match in matches {
            guard let id = (match["element-6066-11e4-a52e-4f735466cecf"] ?? match["ELEMENT"]) as? String else { continue }
            let rect = try await call("GET", "/element/\(id)/rect", inSession: true) as? [String: Any] ?? [:]
            let b = element.bounds
            let sameBounds = [("x", b.x), ("y", b.y), ("width", b.width), ("height", b.height)].allSatisfy { key, expected in
                guard let number = rect[key] as? NSNumber else { return false }
                return abs(number.doubleValue - expected) <= 1
            }
            if sameBounds { ids.append(id) }
        }
        guard let id = ids.first else { throw AgentError(.staleReference, "The native target moved or disappeared. Observe again.") }
        guard ids.count == 1 else { throw AgentError(.ambiguousTarget, "Multiple native elements share this target's bounds.") }
        return id
    }
    func tapElement(_ element: PhoneElement) async throws {
        let id = try await elementID(element)
        try await call("POST", "/element/\(id)/click", inSession: true)
    }
    func fillElement(_ element: PhoneElement, text: String) async throws {
        let id = try await elementID(element)
        try await call("POST", "/element/\(id)/clear", inSession: true)
        if !text.isEmpty { try await call("POST", "/element/\(id)/value", ["value": text.map(String.init)], inSession: true) }
    }
}
