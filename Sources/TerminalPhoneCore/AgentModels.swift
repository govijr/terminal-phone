import Foundation

/// Versioned, provider-independent wire types shared by the CLI, session host and MCP.
public enum PhoneAgentAPI {
    public static let version = "2"
    public static let productVersion = "0.3.0"
}

public struct AgentError: Error, Codable, LocalizedError, Equatable {
    public enum Code: String, Codable {
        case invalidRequest = "INVALID_REQUEST", notReady = "NOT_READY", inputDisabled = "INPUT_DISABLED"
        case controllerBusy = "CONTROLLER_BUSY", staleReference = "STALE_REFERENCE"
        case targetNotFound = "TARGET_NOT_FOUND", ambiguousTarget = "AMBIGUOUS_TARGET"
        case targetDisabled = "TARGET_DISABLED", unsupported = "UNSUPPORTED"
        case deviceLocked = "DEVICE_LOCKED", disconnected = "DISCONNECTED"
        case backendUnavailable = "BACKEND_UNAVAILABLE", waitTimeout = "WAIT_TIMEOUT"
        case actionOutcomeUnknown = "ACTION_OUTCOME_UNKNOWN", observationFailed = "OBSERVATION_FAILED"
        case requestConflict = "REQUEST_CONFLICT"
        case cancelled = "REQUEST_CANCELLED"
    }
    public let code: Code
    public let message: String
    public let recovery: String
    public var errorDescription: String? { message }
    public init(_ code: Code, _ message: String, recovery: String = "Inspect the phone again before continuing.") {
        self.code = code; self.message = message; self.recovery = recovery
    }
    public static func backend(_ error: Error) -> AgentError {
        if let error = error as? AgentError { return error }
        let message = error.localizedDescription
        let lower = message.lowercased()
        if lower.contains("locked") || lower.contains("unlock") {
            return AgentError(.deviceLocked, message, recovery: "Ask the owner to unlock the iPhone, then observe again.")
        }
        if lower.contains("isn't connected") || lower.contains("not connected") || lower.contains("connection") || lower.contains("offline") {
            return AgentError(.disconnected, message, recovery: "Reconnect the selected phone, then observe again.")
        }
        return AgentError(.backendUnavailable, message)
    }
}

public struct PhoneBounds: Codable, Equatable {
    public let x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var center: [Int] { [Int((x + width / 2).rounded()), Int((y + height / 2).rounded())] }
    public func intersects(width screenWidth: Int, height screenHeight: Int) -> Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 &&
        x < Double(screenWidth) && y < Double(screenHeight) && x + width > 0 && y + height > 0
    }
}

public struct PhoneElement: Codable, Equatable {
    public let role: String
    public let identifier: String?
    public let label: String?
    public let value: String?
    public let bounds: PhoneBounds
    public let enabled: Bool
    public let secure: Bool
    public init(role: String, identifier: String? = nil, label: String? = nil, value: String? = nil,
                bounds: PhoneBounds, enabled: Bool = true, secure: Bool = false) {
        self.role = role; self.identifier = identifier; self.label = label
        self.value = secure ? nil : value; self.bounds = bounds; self.enabled = enabled; self.secure = secure
    }
}

public struct PhoneAppContext: Codable, Equatable {
    public let bundleId: String?
    public let name: String?
    public init(bundleId: String? = nil, name: String? = nil) { self.bundleId = bundleId; self.name = name }
}

public struct PhoneScene: Codable, Equatable {
    public let width: Int, height: Int
    public let scale: Double
    public let orientation: String
    public let app: PhoneAppContext
    public let elements: [PhoneElement]
    public init(width: Int, height: Int, scale: Double, orientation: String, app: PhoneAppContext, elements: [PhoneElement]) {
        self.width = width; self.height = height; self.scale = scale; self.orientation = orientation
        self.app = app; self.elements = elements
    }
}

public struct PhoneCapture {
    public let scene: PhoneScene
    public let png: Data
    public let startedAt: Date
    public let finishedAt: Date
    public init(scene: PhoneScene, png: Data, startedAt: Date = Date(), finishedAt: Date = Date()) {
        self.scene = scene; self.png = png; self.startedAt = startedAt; self.finishedAt = finishedAt
    }
}

public struct ObservedElement: Codable {
    public let ref: String
    public let element: PhoneElement
    public init(ref: String, element: PhoneElement) { self.ref = ref; self.element = element }
}

public struct PhoneObservation: Codable {
    public let id: String
    public let sessionId: String
    public let name: String
    public let udid: String
    public let kind: String
    public let capturedFrom: Date
    public let capturedAt: Date
    public let coordinateSpace: String
    public let width: Int, height: Int
    public let scale: Double
    public let orientation: String
    public let app: PhoneAppContext
    public let screenshot: String?
    public let elements: [ObservedElement]
    /// Screenshot and accessibility data are collected in sequence, never advertised as atomic.
    public let consistency: String
}

public struct PhoneCapabilities: Codable {
    public let backend: String
    public let inputAllowed: Bool
    public let foregroundApp: Bool
    public let elementActions: String
    public let actions: [PhoneAction.Kind]
    public init(backend: String, inputAllowed: Bool, foregroundApp: Bool, elementActions: String, actions: [PhoneAction.Kind]) {
        self.backend = backend; self.inputAllowed = inputAllowed; self.foregroundApp = foregroundApp
        self.elementActions = elementActions; self.actions = actions
    }
}

public struct ElementSelector: Codable, Equatable {
    public var ref: String?
    public var identifier: String?
    public var label: String?
    public var role: String?
    public init(ref: String? = nil, identifier: String? = nil, label: String? = nil, role: String? = nil) {
        self.ref = ref; self.identifier = identifier; self.label = label; self.role = role
    }
    public var isEmpty: Bool { ref == nil && identifier == nil && label == nil && role == nil }
    public func matches(_ element: PhoneElement) -> Bool {
        (identifier == nil || identifier == element.identifier) && (label == nil || label == element.label) &&
        (role == nil || role == element.role)
    }
}

public struct PhoneAction: Codable, Equatable {
    public enum Kind: String, Codable, CaseIterable { case tap, fill, type, swipe, scroll, press, launch, open, install }
    public let kind: Kind
    public var target: ElementSelector?
    public var text: String?
    public var coordinates: [Int]?
    public var direction: String?
    public var duration: Double?
    public init(kind: Kind, target: ElementSelector? = nil, text: String? = nil, coordinates: [Int]? = nil,
                direction: String? = nil, duration: Double? = nil) {
        self.kind = kind; self.target = target; self.text = text; self.coordinates = coordinates
        self.direction = direction; self.duration = duration
    }
    public func validate() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw AgentError(.invalidRequest, message) }
        }
        if let duration { try require(duration.isFinite && (0.05...10).contains(duration), "Duration must be 0.05–10 seconds.") }
        if let coordinates { try require(coordinates.allSatisfy { (0...16384).contains($0) }, "Coordinates must be display points in 0...16384.") }
        if let target {
            try require(!target.isEmpty, "An element selector must contain a reference, identifier, label or role.")
            try require(coordinates == nil, "Use an element selector or coordinates, not both.")
            try require(target.ref == nil || (target.identifier == nil && target.label == nil && target.role == nil), "A reference cannot be combined with other selectors.")
        }
        switch kind {
        case .tap: try require(target != nil || coordinates?.count == 2, "Tap needs an element selector or two coordinates.")
        case .fill:
            try require(target != nil && text != nil, "Fill needs an element selector and text (which may be empty).")
        case .type, .press, .launch, .open, .install:
            try require(text?.isEmpty == false, "\(kind.rawValue) needs nonempty text.")
            try require(target == nil && coordinates == nil, "\(kind.rawValue) does not accept a target or coordinates.")
        case .swipe: try require(target == nil && coordinates?.count == 4, "Swipe needs four coordinates.")
        case .scroll:
            try require(["up", "down", "left", "right"].contains(direction), "Scroll direction must be up, down, left or right.")
            try require(coordinates == nil, "Scroll accepts an optional element selector, not coordinates.")
        }
        try require(text == nil || text!.utf8.count <= 64 * 1024, "Text is limited to 64 KiB per action.")
        try require(text == nil || !text!.contains("\0"), "Text cannot contain NUL characters.")
        try require(duration == nil || [.swipe, .scroll].contains(kind), "Duration is supported only for swipe and scroll.")
        try require(direction == nil || kind == .scroll, "Direction is supported only for scroll.")
        try require(text == nil || ![.tap, .swipe, .scroll].contains(kind), "This action does not accept text.")
    }
}

public struct PhoneWaitCondition: Codable, Equatable {
    public let text: String?
    public let identifier: String?
    public let app: String?
    public let absent: Bool
    public init(text: String? = nil, identifier: String? = nil, app: String? = nil, absent: Bool = false) {
        self.text = text; self.identifier = identifier; self.app = app; self.absent = absent
    }
    private enum CodingKeys: String, CodingKey { case text, identifier, app, absent }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decodeIfPresent(String.self, forKey: .text)
        identifier = try values.decodeIfPresent(String.self, forKey: .identifier)
        app = try values.decodeIfPresent(String.self, forKey: .app)
        absent = try values.decodeIfPresent(Bool.self, forKey: .absent) ?? false
    }
    public func validate() throws {
        guard [text, identifier, app].contains(where: { $0?.isEmpty == false }),
              [text, identifier, app].allSatisfy({ $0 == nil || $0?.isEmpty == false }) else {
            throw AgentError(.invalidRequest, "Wait needs nonempty text, identifier or app.")
        }
    }
    public func matches(_ scene: PhoneScene) -> Bool {
        let appMatches = app == nil || app == scene.app.bundleId
        let elementMatches = (text == nil && identifier == nil) || scene.elements.contains { element in
            (identifier == nil || identifier == element.identifier) &&
            (text == nil || [element.label, element.value].compactMap { $0 }.contains { $0.contains(text!) })
        }
        let present = appMatches && elementMatches
        return absent ? !present : present
    }
}

public struct PhoneAgentRequest: Codable, Equatable {
    public enum Operation: String, Codable { case status, capabilities, observe, act, input, wait, release }
    public var id: String
    public let operation: Operation
    public var action: PhoneAction?
    public var condition: PhoneWaitCondition?
    public var timeout: Double
    public var includeImage: Bool
    public var observeAfter: Bool
    public var sessionId: String?
    public init(operation: Operation, id: String = UUID().uuidString, action: PhoneAction? = nil,
                condition: PhoneWaitCondition? = nil, timeout: Double = 10, includeImage: Bool = true,
                observeAfter: Bool = false, sessionId: String? = nil) {
        self.operation = operation; self.id = id; self.action = action; self.condition = condition
        self.timeout = timeout; self.includeImage = includeImage; self.observeAfter = observeAfter; self.sessionId = sessionId
    }
    public func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 128, timeout.isFinite, (0...120).contains(timeout) else {
            throw AgentError(.invalidRequest, "Use a request ID up to 128 bytes and a timeout between 0 and 120 seconds.")
        }
        if operation == .act || operation == .input { guard let action else { throw AgentError(.invalidRequest, "Missing action.") }; try action.validate() }
        else if action != nil { throw AgentError(.invalidRequest, "Actions are accepted only by act.") }
        if operation == .input {
            guard let action, [.tap, .swipe, .type, .press].contains(action.kind), action.target == nil,
                  condition == nil, !observeAfter else { throw AgentError(.invalidRequest, "Viewer input accepts raw touch, typing and button events only.") }
        }
        if let condition { try condition.validate() }
        if operation == .wait, condition == nil { throw AgentError(.invalidRequest, "Missing wait condition.") }
        if condition != nil, operation != .wait && operation != .act { throw AgentError(.invalidRequest, "Unexpected wait condition.") }
    }
}

public struct PhoneSessionInfo: Codable {
    public let id: String, name: String, udid: String, kind: String
    public let startedAt: Date
    public let inputAllowed: Bool
    public let controlsInput: Bool
}

public struct PhoneActionReceipt: Codable {
    public let kind: PhoneAction.Kind
    public let outcome: String
    public let verified: Bool
}

public struct PhoneAgentReply: Codable {
    public let schemaVersion: String
    public let id: String
    public let ok: Bool
    public let session: PhoneSessionInfo
    public let observation: PhoneObservation?
    public let capabilities: PhoneCapabilities?
    public let action: PhoneActionReceipt?
    public let error: AgentError?
}

/// Adapters own platform details. The session owns targeting, ordering, references and recovery.
@MainActor
public protocol PhoneBackend: AnyObject {
    var phone: Phone { get }
    func capabilities(inputAllowed: Bool) -> PhoneCapabilities
    func capture() async throws -> PhoneCapture
    func perform(_ action: PhoneAction, target: PhoneElement?) async throws
    func close()
}

public enum PhoneAgentCoding {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
}
