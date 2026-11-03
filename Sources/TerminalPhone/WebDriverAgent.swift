import Foundation
import TerminalMacCore
import TerminalPhoneCore

/// A small client for WebDriverAgent running on a real iPhone. Coordinates are display points,
/// the same space idb uses for simulators, so agents can drive either kind the same way.
final class WebDriverAgent: @unchecked Sendable {
    static let port = 8100, mjpegPort = 9100
    let host: String
    private let http: URLSession
    private let lock = NSLock()
    private var session: String?

    init(host: String, session: URLSession? = nil) {
        self.host = host
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 4
        http = session ?? URLSession(configuration: configuration)
    }
    /// IPv6 tunnel addresses need brackets in URLs.
    static func url(host: String, port: Int, path: String = "") -> URL {
        URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):\(port)\(path)")!
    }

    @discardableResult
    func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, inSession: Bool = false, timeout: TimeInterval = 30, retryInvalidSession: Bool = true) async throws -> Any {
        let prefix = inSession ? "/session/\(try await ensureSession())" : ""
        var request = URLRequest(url: Self.url(host: host, port: Self.port, path: prefix + path), timeoutInterval: timeout)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await http.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let value = json?["value"]
        if let error = value as? [String: Any], let kind = error["error"] as? String {
            // A stale session (WDA restarted) gets one fresh retry.
            if inSession, kind == "invalid session id", retryInvalidSession {
                lock.withLock { session = nil }
                return try await call(method, path, body, inSession: true, timeout: timeout, retryInvalidSession: false)
            }
            throw Failure("WebDriverAgent: \(error["message"] as? String ?? kind)")
        }
        guard (response as? HTTPURLResponse)?.statusCode ?? 500 < 400 else { throw Failure("WebDriverAgent returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
        if path == "/status", let current = json?["sessionId"] as? String, !current.isEmpty {
            lock.withLock { session = current }
        }
        return value ?? NSNull()
    }
    func ready(timeout: TimeInterval = 3) async -> Bool {
        (try? await call("GET", "/status", timeout: timeout)) != nil
    }
    private func ensureSession() async throws -> String {
        if let session = lock.withLock({ session }) { return session }
        // A read-only viewer and the agent share WDA; don't replace each other's native session.
        _ = try await call("GET", "/status")
        if let session = lock.withLock({ session }) { return session }
        let value = try await call("POST", "/session", ["capabilities": ["alwaysMatch": [String: Any](), "firstMatch": [[String: Any]()]]])
        guard let id = (value as? [String: Any])?["sessionId"] as? String else { throw Failure("WebDriverAgent did not create a session") }
        lock.withLock { session = id }
        return id
    }

    // MARK: Screen

    /// Display points and the points-to-pixels scale.
    func screen() async throws -> PhoneScreen {
        let info = try await call("GET", "/wda/screen") as? [String: Any]
        let size = try await call("GET", "/window/size") as? [String: Any]
        guard let scale = (info?["scale"] as? NSNumber)?.doubleValue, (1...4).contains(scale),
              let width = (size?["width"] as? NSNumber)?.doubleValue, let height = (size?["height"] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { throw Failure("WebDriverAgent did not report the screen size") }
        return PhoneScreen(scale: scale, nativeWidth: Int((width * scale).rounded()), nativeHeight: Int((height * scale).rounded()))
    }
    func screenshot() async throws -> Data {
        guard let base64 = try await call("GET", "/screenshot", timeout: 30) as? String, let data = Data(base64Encoded: base64) else {
            throw Failure("WebDriverAgent returned an invalid screenshot")
        }
        return data
    }
    /// Configures the MJPEG server on port 9100. `scale` is a fraction of the native resolution.
    func configureStream(scale: Double, fps: Int = 30, quality: Int = 80) async throws {
        try await call("POST", "/appium/settings", ["settings": ["mjpegServerFramerate": fps, "mjpegServerScreenshotQuality": quality,
                                                                  "mjpegScalingFactor": Int((scale * 100).rounded()), "mjpegFixOrientation": true]], inSession: true)
    }

    // MARK: Input

    func tap(_ x: Int, _ y: Int) async throws { try await call("POST", "/wda/tap", ["x": x, "y": y], inSession: true) }
    func swipe(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int, duration: Double) async throws {
        // WDA's duration is the initial press; the drag itself follows at a natural speed.
        try await call("POST", "/wda/dragfromtoforduration", ["fromX": x1, "fromY": y1, "toX": x2, "toY": y2, "duration": min(max(duration, 0.05), 10)], inSession: true)
    }
    func type(_ text: String) async throws { try await call("POST", "/wda/keys", ["value": text.map(String.init)], inSession: true, timeout: 60) }
    /// Keys use XCUIKeyboardKey characters. Arrow keys only work with a hardware keyboard attached.
    static let keys: [String: String] = ["return": "\n", "backspace": "\u{8}", "tab": "\t", "escape": "\u{1b}", "delete": "\u{7f}",
                                         "up": "\u{F700}", "down": "\u{F701}", "left": "\u{F702}", "right": "\u{F703}"]
    func button(_ name: String) async throws {
        switch name.uppercased() {
        case "HOME": try await call("POST", "/wda/homescreen")
        case "LOCK": try await call("POST", "/wda/lock")
        case "VOLUMEUP": try await call("POST", "/wda/pressButton", ["name": "volumeUp"], inSession: true)
        case "VOLUMEDOWN": try await call("POST", "/wda/pressButton", ["name": "volumeDown"], inSession: true)
        default: throw Failure("Supported buttons on a real iPhone: HOME, LOCK, VOLUMEUP, VOLUMEDOWN")
        }
    }
    func open(_ url: String) async throws { try await call("POST", "/url", ["url": url], inSession: true) }
    func appearance(dark: Bool) async throws { try await call("POST", "/wda/device/appearance", ["name": dark ? "dark" : "light"]) }

    /// Flattens WDA's tree into idb's describe-all shape, so agents see one schema for both kinds.
    /// Only elements that overlap the screen are returned, like idb's describe-all.
    func describe() async throws -> [[String: Any]] {
        let size = try await call("GET", "/window/size") as? [String: Any]
        let screenWidth = (size?["width"] as? NSNumber)?.doubleValue ?? .infinity, screenHeight = (size?["height"] as? NSNumber)?.doubleValue ?? .infinity
        // Visibility and the other computed attributes are slow on busy screens; bounds are enough.
        let slow = "visible,accessible,nativeAccessibilityElement,focused,nativeFrame,traits,minValue,maxValue,placeholderValue,frame"
        let tree = try await call("GET", "/source?format=json&excluded_attributes=\(slow)", timeout: 60)
        var elements: [[String: Any]] = []
        func visit(_ node: Any) {
            guard let node = node as? [String: Any] else { return }
            let rect = node["rect"] as? [String: Any] ?? [:]
            let frame = ["x": rect["x"] ?? 0, "y": rect["y"] ?? 0, "width": rect["width"] ?? 0, "height": rect["height"] ?? 0]
            let visible = (node["isVisible"] as? NSNumber)?.boolValue ?? true
            let x = (rect["x"] as? NSNumber)?.doubleValue ?? 0, y = (rect["y"] as? NSNumber)?.doubleValue ?? 0
            let width = (rect["width"] as? NSNumber)?.doubleValue ?? 0, height = (rect["height"] as? NSNumber)?.doubleValue ?? 0
            let onScreen = x < screenWidth && y < screenHeight && x + width > 0 && y + height > 0
            if visible, onScreen, width > 0, height > 0 {
                func text(_ key: String) -> Any { (node[key] as? String).map { $0 as Any } ?? NSNull() }
                elements.append(["type": node["type"] ?? NSNull(), "AXLabel": text("label"), "AXUniqueId": text("rawIdentifier"),
                                 "AXValue": text("value"), "name": text("name"), "frame": frame,
                                 "enabled": (node["isEnabled"] as? NSNumber)?.boolValue ?? true])
            }
            (node["children"] as? [Any])?.forEach(visit)
        }
        visit(tree)
        return elements
    }
}

/// Reads WDA's multipart MJPEG stream and hands out whole JPEG frames on URLSession's queue.
final class MJPEGReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var buffer = Data()
    private let onFrame: @Sendable (Data) -> Void
    private let onEnd: @Sendable (String) -> Void
    private var task: URLSessionDataTask?
    private var session: URLSession?

    init(url: URL, onFrame: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable (String) -> Void) {
        self.onFrame = onFrame; self.onEnd = onEnd
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = .infinity
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        task = session.dataTask(with: url)
        task?.resume()
    }
    func cancel() { task?.cancel(); session?.invalidateAndCancel() }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        // JPEG markers: entropy-coded data never contains FF D8 / FF D9 unescaped.
        while let start = buffer.firstRange(of: Data([0xFF, 0xD8])) {
            guard let end = buffer[start.upperBound...].firstRange(of: Data([0xFF, 0xD9])) else {
                if start.lowerBound > 0 { buffer.removeSubrange(..<start.lowerBound) }
                if buffer.count > 16 * 1024 * 1024 { buffer.removeAll() }
                return
            }
            onFrame(Data(buffer[start.lowerBound..<end.upperBound]))
            buffer.removeSubrange(..<end.upperBound)
        }
        if buffer.count > 1 { buffer.removeSubrange(..<(buffer.count - 1)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if (error as? URLError)?.code != .cancelled { onEnd(error?.localizedDescription ?? "The iPhone video stream ended") }
    }
}
