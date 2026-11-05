import Foundation
import TerminalPhoneCore
import TerminalMacCore

@MainActor
extension PhoneCLI {
    func agentCommand(_ command: String, _ input: [String]) async throws {
        if command == "schema" {
            guard input.isEmpty else { throw AgentError(.invalidRequest, "Usage: terminal-phone schema") }
            try printJSON(["schemaVersion": PhoneAgentAPI.version, "tools": PhoneAgentTools.definitions]); return
        }
        if command == "mcp" {
            if let first = input.first, ["install", "uninstall"].contains(first) { try await mcpConfigCommand(input); return }
            guard input.isEmpty else { throw AgentError(.invalidRequest, "Usage: terminal-phone mcp  (stdio server)\n\(Self.mcpConfigUsage)") }
            await PhoneMCPServer(cli: self).run(); return
        }
        if command == "session" {
            let args = try Arguments(input)
            guard let operation = args.positionals.first, ["start", "status", "release", "stop"].contains(operation) else {
                throw AgentError(.invalidRequest, "Usage: terminal-phone session start|status|release|stop [NAME]")
            }
            let name = try named(Array(args.positionals.dropFirst()))
            if operation == "stop" {
                try printJSON(["ok": true, "name": name, "stopped": try await PhoneAgentClient.stop(cli: self, name: name)]); return
            }
            try await emitAgent(name: name, request: PhoneAgentRequest(operation: operation == "release" ? .release : .status), start: operation == "start")
            return
        }
        let args = try Arguments(input, flags: ["no-image", "observe", "absent"],
                                 options: ["ref", "id", "label", "role", "text", "x", "y", "x2", "y2", "direction", "duration",
                                           "timeout", "app", "wait-text", "wait-id", "wait-app", "request-id", "session"])
        var positions = args.positionals
        let name: String
        if command == "act" {
            guard !positions.isEmpty else { throw AgentError(.invalidRequest, "Usage: terminal-phone act [NAME] ACTION [options]") }
            let verbs = Set(PhoneAction.Kind.allCases.map(\.rawValue))
            name = verbs.contains(positions[0]) ? defaultName : positions.removeFirst()
        } else { name = try named(positions); positions = [] }
        try validateName(name)
        let timeout = try number(args.options["timeout"], fallback: 10, range: 0...120, name: "timeout")
        var request = PhoneAgentRequest(operation: command == "act" ? .act : command == "wait" ? .wait : command == "capabilities" ? .capabilities : .observe,
                                       id: args.options["request-id"] ?? UUID().uuidString, timeout: timeout,
                                       includeImage: !args.flags.contains("no-image"), observeAfter: args.flags.contains("observe"), sessionId: args.options["session"])
        if command == "act" {
            guard !positions.isEmpty, let kind = PhoneAction.Kind(rawValue: positions.removeFirst()) else { throw AgentError(.invalidRequest, "Unknown agent action.") }
            let selector = ElementSelector(ref: args.options["ref"], identifier: args.options["id"], label: args.options["label"], role: args.options["role"])
            let coordinateKeys = ["x", "y", "x2", "y2"]
            let coordinateOptions = coordinateKeys.compactMap { args.options[$0] }
            var coordinates: [Int]?
            if !coordinateOptions.isEmpty {
                let expected = kind == .swipe ? 4 : 2
                guard coordinateOptions.count == expected, coordinateKeys.prefix(expected).allSatisfy({ args.options[$0] != nil }) else {
                    throw AgentError(.invalidRequest, "Use --x and --y (plus --x2 and --y2 for swipe).")
                }
                coordinates = try coordinateOptions.map(PhoneInput.coordinate)
            }
            var text = args.options["text"], direction = args.options["direction"]
            if !positions.isEmpty {
                if kind == .tap || kind == .swipe {
                    guard coordinates == nil else { throw AgentError(.invalidRequest, "Duplicate coordinates.") }
                    coordinates = try positions.map(PhoneInput.coordinate)
                } else if kind == .scroll {
                    guard positions.count == 1, direction == nil else { throw AgentError(.invalidRequest, "Provide one scroll direction.") }
                    direction = positions[0]
                } else {
                    guard positions.count == 1, text == nil else { throw AgentError(.invalidRequest, "Provide text as one argument or with --text.") }
                    text = positions[0]
                }
            }
            let duration = try args.options["duration"].map { try number($0, fallback: 0.3, range: 0.05...10, name: "duration") }
            request.action = PhoneAction(kind: kind, target: selector.isEmpty ? nil : selector, text: text,
                                         coordinates: coordinates, direction: direction, duration: duration)
            if args.options["wait-text"] != nil || args.options["wait-id"] != nil || args.options["wait-app"] != nil {
                request.condition = PhoneWaitCondition(text: args.options["wait-text"], identifier: args.options["wait-id"], app: args.options["wait-app"], absent: args.flags.contains("absent"))
            }
        } else if command == "wait" {
            request.condition = PhoneWaitCondition(text: args.options["text"], identifier: args.options["id"], app: args.options["app"], absent: args.flags.contains("absent"))
        }
        // Reject accepted-but-ignored flags so an agent never mistakes a no-op for a guarantee.
        let common: Set<String> = ["request-id", "session"]
        let allowed: Set<String> = command == "act" ? common.union(["ref", "id", "label", "role", "text", "x", "y", "x2", "y2", "direction", "duration", "timeout", "wait-text", "wait-id", "wait-app"]) :
            command == "wait" ? common.union(["text", "id", "app", "timeout"]) : common
        guard Set(args.options.keys).isSubset(of: allowed),
              !args.flags.contains("observe") || command == "act",
              !args.flags.contains("absent") || request.condition != nil,
              !args.flags.contains("no-image") || command != "capabilities" else {
            throw AgentError(.invalidRequest, "One or more options are not supported by this command.")
        }
        try await emitAgent(name: name, request: request)
    }

    func emitAgent(name: String, request: PhoneAgentRequest, start: Bool = true) async throws {
        let reply = try await PhoneAgentClient.request(cli: self, name: name, request: request, start: start)
        FileHandle.standardOutput.write(try PhoneAgentCoding.encoder(pretty: true).encode(reply) + Data([10]))
        if !reply.ok { exit(1) }
    }

    func number(_ raw: String?, fallback: Double, range: ClosedRange<Double>, name: String) throws -> Double {
        guard let raw else { return fallback }
        guard let value = Double(raw), value.isFinite, range.contains(value) else { throw AgentError(.invalidRequest, "--\(name) must be between \(range.lowerBound) and \(range.upperBound).") }
        return value
    }

    func legacyAgentAction(name: String, verb: String, values: [String], duration: String?) async throws {
        let action: PhoneAction
        switch verb {
        case "tap": action = PhoneAction(kind: .tap, coordinates: try values.map(PhoneInput.coordinate))
        case "swipe": action = PhoneAction(kind: .swipe, coordinates: try values.map(PhoneInput.coordinate), duration: try number(duration, fallback: 0.3, range: 0.05...10, name: "duration"))
        case "type":
            guard values.count == 1 else { throw AgentError(.invalidRequest, "Type needs one text argument.") }
            action = PhoneAction(kind: .type, text: values[0])
        case "key", "button":
            guard values.count == 1 else { throw AgentError(.invalidRequest, "Expected one key or button.") }
            if verb == "key", PhoneAgentBackends.keys[values[0]] == nil { throw AgentError(.invalidRequest, "Unsupported key: \(values[0]).") }
            if verb == "button" {
                let buttons = try store.load(name).isDevice ? ["HOME", "LOCK", "VOLUMEUP", "VOLUMEDOWN"] : ["HOME", "LOCK", "SIRI"]
                guard buttons.contains(values[0].uppercased()) else { throw AgentError(.invalidRequest, "Unsupported button: \(values[0]).") }
            }
            action = PhoneAction(kind: .press, text: values[0])
        default: throw AgentError(.invalidRequest, "Unknown legacy input action.")
        }
        let reply = try await PhoneAgentClient.request(cli: self, name: name, request: PhoneAgentRequest(operation: .act, action: action, includeImage: false))
        if let error = reply.error { throw error }
        try printJSON(["ok": true, "name": name, "udid": reply.session.udid, "action": verb])
    }
}
