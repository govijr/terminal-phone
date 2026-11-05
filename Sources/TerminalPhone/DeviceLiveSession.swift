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
    private var reconnects = 0, recovering = false
    private var monitor: Task<Void, Never>?
    /// Whether WebDriverAgent last reported the iPhone as locked.
    private(set) var locked = false
    private var stream: (cli: PhoneCLI, phone: Phone, scale: Double, frames: @Sendable (Data) -> Void)?

    /// WDA encodes on the phone: half resolution at quality 70 holds 25-30 fps over Wi-Fi.
    static let maxScale = 0.5

    func start(cli: PhoneCLI, phone: Phone, streamScale: Double, frames: @escaping @Sendable (Data) -> Void) async throws {
        stream = (cli, phone, min(streamScale, Self.maxScale), frames)
        try await openStream()
        onEvent?(["event": "ready"])
        watchLock()
    }
    /// iOS stops capture and input while the iPhone is locked. Report it, so the viewer can
    /// say so instead of looking frozen, and resume by itself after the owner unlocks.
    private func watchLock() {
        monitor?.cancel()
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !self.stopped else { return }
                if let agent = self.agent, let value = try? await agent.call("GET", "/wda/locked", timeout: 3) as? Bool, value != self.locked {
                    self.locked = value
                    self.onEvent?(["event": value ? "locked" : "unlocked"])
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }
    /// A new size only needs new settings and a new video connection; input keeps its client and session.
    func rescale(_ scale: Double) async throws {
        guard var stream, let agent, !stopped else { return }
        stream.scale = min(scale, Self.maxScale); self.stream = stream
        try await agent.configureStream(scale: stream.scale, quality: 70)
        guard !stopped else { return }
        openReader(agent)
    }
    private func openStream() async throws {
        guard let stream, !stopped else { return }
        let agent = try await PhoneDevices.connect(stream.cli, stream.phone, progress: false)
        guard !stopped else { return }
        self.agent = agent
        try await agent.configureStream(scale: stream.scale, quality: 70)
        openReader(agent)
    }
    private func openReader(_ agent: WebDriverAgent) {
        guard let stream else { return }
        reader?.cancel()
        reader = MJPEGReader(url: WebDriverAgent.url(host: agent.host, port: WebDriverAgent.mjpegPort), onFrame: { [weak self] frame in
            stream.frames(frame)
            Task { @MainActor [weak self] in self?.reconnects = 0 }
        }, onEnd: { message in
            Task { @MainActor [weak self] in await self?.streamEnded(message) }
        })
    }
    /// CoreDevice recreates idle tunnels with new addresses, and a locked or sleeping iPhone drops
    /// off Wi-Fi. Retry quickly twice, then keep waiting for the phone instead of giving up.
    private func streamEnded(_ message: String) async {
        guard !stopped, !recovering else { return }
        recovering = true
        defer { recovering = false }
        var message = message, waiting = false
        while !stopped {
            reconnects += 1
            // The tunnel may have a new address now, so look the device up again.
            if let phone = stream?.phone { PhoneDevices.forget(phone) }
            if reconnects == 3 {
                waiting = true
                onEvent?(["event": "waiting", "message": "\(stream?.phone.displayModel ?? "iPhone") is locked or out of reach. Unlock it to continue.", "detail": message])
            }
            try? await Task.sleep(nanoseconds: reconnects <= 2 ? UInt64(reconnects) * 400_000_000 : 2_000_000_000)
            guard !stopped else { return }
            do {
                try await openStream()
                if waiting { onEvent?(["event": "ready"]) }
                return
            } catch { message = error.localizedDescription }
        }
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
        monitor?.cancel(); monitor = nil
        reader?.cancel(); reader = nil
    }
    var client: WebDriverAgent? { agent }
}
