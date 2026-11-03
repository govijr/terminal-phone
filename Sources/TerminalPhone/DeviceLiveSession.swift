import Foundation
import TerminalMacCore
import TerminalPhoneCore

/// What the viewer needs from a live connection: ordered input with acks, events, and teardown.
/// Events use the worker's vocabulary: "ready", "ack", "input-error" and "fatal".
@MainActor
protocol PhoneLink: AnyObject {
    var onEvent: (([String: Any]) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func send(_ request: [String: Any]) throws
    func stop()
}

extension PhoneLiveSession: PhoneLink {}

/// A real iPhone through WebDriverAgent: MJPEG video from port 9100, input over HTTP.
@MainActor
final class DeviceLiveSession: PhoneLink {
    var onEvent: (([String: Any]) -> Void)?
    var onFailure: ((String) -> Void)?
    private var agent: WebDriverAgent?
    private var reader: MJPEGReader?
    private var stopped = false
    private var reconnects = 0
    private var stream: (cli: PhoneCLI, phone: Phone, scale: Double, frames: @Sendable (Data) -> Void)?

    func start(cli: PhoneCLI, phone: Phone, streamScale: Double, frames: @escaping @Sendable (Data) -> Void) async throws {
        // WDA encodes on the phone: half resolution at quality 70 holds 25-30 fps over Wi-Fi.
        stream = (cli, phone, min(streamScale, 0.5), frames)
        try await openStream()
        onEvent?(["event": "ready"])
    }
    private func openStream() async throws {
        guard let stream, !stopped else { return }
        let agent = try await PhoneDevices.connect(stream.cli, stream.phone, progress: false)
        guard !stopped else { return }
        self.agent = agent
        try await agent.configureStream(scale: stream.scale, quality: 70)
        reader?.cancel()
        reader = MJPEGReader(url: WebDriverAgent.url(host: agent.host, port: WebDriverAgent.mjpegPort), onFrame: { [weak self] frame in
            stream.frames(frame)
            Task { @MainActor [weak self] in self?.reconnects = 0 }
        }, onEnd: { message in
            Task { @MainActor [weak self] in await self?.streamEnded(message) }
        })
    }
    /// CoreDevice recreates idle tunnels with new addresses; reconnect instead of giving up.
    private func streamEnded(_ message: String) async {
        guard !stopped else { return }
        reconnects += 1
        guard reconnects <= 5 else { onFailure?("iPhone stream ended: \(message)"); return }
        try? await Task.sleep(nanoseconds: UInt64(reconnects) * 700_000_000)
        do { try await openStream() } catch { await streamEnded(error.localizedDescription) }
    }
    func send(_ request: [String: Any]) throws {
        guard let agent else { throw Failure("The iPhone is not connected yet") }
        let id = request["id"] as? Int ?? 0
        let action = request["action"] as? String ?? "", values = (request["values"] as? [String]) ?? []
        let duration = request["duration"] as? Double ?? 0.2
        Task { @MainActor [weak self] in
            let started = Date()
            do {
                let n = values.compactMap { Int($0) }
                switch action {
                case "tap" where n.count == 2: try await agent.tap(n[0], n[1])
                case "swipe" where n.count == 4: try await agent.swipe(n[0], n[1], n[2], n[3], duration: duration)
                case "type" where values.count == 1: try await agent.type(values[0])
                case "button" where values.count == 1: try await agent.button(values[0])
                case "key" where values.count == 1:
                    // The viewer sends HID usage codes; WDA wants keyboard characters.
                    let names = [40: "return", 41: "escape", 42: "backspace", 43: "tab", 76: "delete", 79: "right", 80: "left", 81: "down", 82: "up"]
                    guard let name = Int(values[0]).flatMap({ names[$0] }), let key = WebDriverAgent.keys[name] else { throw Failure("Unsupported key") }
                    try await agent.type(key)
                default: throw Failure("Unsupported input on a real iPhone")
                }
                self?.onEvent?(["event": "ack", "id": id, "milliseconds": Date().timeIntervalSince(started) * 1000])
            } catch {
                // Like the simulator path, input is never replayed: it may already have landed.
                self?.onEvent?(["event": "input-error", "id": id, "error": error.localizedDescription])
            }
        }
    }
    func stop() {
        stopped = true
        reader?.cancel(); reader = nil
    }
    var client: WebDriverAgent? { agent }
}
