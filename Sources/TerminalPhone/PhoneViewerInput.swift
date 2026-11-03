import Foundation
import TerminalPhoneCore

/// The viewer shares native input ordering with agents; streaming never owns the controller lock.
@MainActor
final class PhoneViewerInput {
    private let cli: PhoneCLI
    private let phone: Phone
    private var task: Task<Void, Never>?
    var onEvent: (([String: Any]) -> Void)?
    init(cli: PhoneCLI, phone: Phone) { self.cli = cli; self.phone = phone }
    func send(_ request: [String: Any]) {
        let id = request["id"] as? Int ?? 0
        let verb = request["action"] as? String ?? ""
        let values = request["values"] as? [String] ?? []
        let started = Date()
        task = Task { @MainActor in
            do {
                let action: PhoneAction
                switch verb {
                case "tap": action = PhoneAction(kind: .tap, coordinates: try values.map(PhoneInput.coordinate))
                case "swipe": action = PhoneAction(kind: .swipe, coordinates: try values.map(PhoneInput.coordinate), duration: request["duration"] as? Double ?? 0.3)
                case "type": action = PhoneAction(kind: .type, text: values.first)
                case "button": action = PhoneAction(kind: .press, text: values.first)
                case "key":
                    let codes = Dictionary(uniqueKeysWithValues: PhoneAgentBackends.keys.map { ($0.value, $0.key) })
                    guard let code = values.first.flatMap(Int.init), let key = codes[code] else { throw AgentError(.invalidRequest, "Unsupported keyboard key.") }
                    action = PhoneAction(kind: .press, text: key)
                default: throw AgentError(.invalidRequest, "Unsupported viewer event.")
                }
                let reply = try await PhoneAgentClient.request(cli: cli, name: phone.name,
                    request: PhoneAgentRequest(operation: .input, action: action, includeImage: false))
                if let error = reply.error { throw error }
                if !Task.isCancelled { onEvent?(["event": "ack", "id": id, "milliseconds": Date().timeIntervalSince(started) * 1000]) }
            } catch {
                if !Task.isCancelled { onEvent?(["event": "input-error", "id": id, "error": error.localizedDescription]) }
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
}
