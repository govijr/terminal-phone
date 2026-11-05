import Foundation

/// A test flow: a list of steps in a small YAML subset, one `- verb: value` per line.
///
///     - launch: com.example.app
///     - tap: "Sign in"                 # an element whose label or identifier is this text
///     - fill: {id: email, text: "me@example.com"}
///     - tap: [120, 480]
///     - expect: "Welcome"              # waits until this text is on screen
///     - expect-not: {text: "Error", timeout: 3}
///     - wait: 1.5
///     - screenshot: home.png
public struct PhoneFlow: Equatable {
    public let steps: [PhoneFlowStep]
    public init(steps: [PhoneFlowStep]) { self.steps = steps }
}

public struct PhoneFlowStep: Equatable {
    public enum Kind: Equatable {
        /// An action sent as is.
        case act(PhoneAction)
        /// Tap whatever element shows this text, as its label or its identifier.
        case tapText(String)
        case expect(PhoneWaitCondition, timeout: Double?)
        case pause(Double)
        case screenshot(String)
    }
    public let line: Int
    public let source: String
    public let kind: Kind
    public init(line: Int, source: String, kind: Kind) { self.line = line; self.source = source; self.kind = kind }
}

public struct PhoneFlowError: Error, LocalizedError, Equatable {
    public let line: Int
    public let message: String
    public var errorDescription: String? { "line \(line): \(message)" }
}

/// A parsed flow value: a scalar, a `[list]` or a `{map}`.
public indirect enum PhoneFlowValue: Equatable {
    case string(String), number(Double), list([PhoneFlowValue]), map([(String, PhoneFlowValue)])
    public static func == (a: PhoneFlowValue, b: PhoneFlowValue) -> Bool {
        switch (a, b) {
        case let (.string(x), .string(y)): x == y
        case let (.number(x), .number(y)): x == y
        case let (.list(x), .list(y)): x == y
        case let (.map(x), .map(y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }
    var text: String? {
        switch self {
        case .string(let value): value
        case .number(let value): value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
        default: nil
        }
    }
    var number: Double? { if case .number(let value) = self { value } else if case .string(let value) = self { Double(value) } else { nil } }
    var integers: [Int]? {
        guard case .list(let items) = self else { return nil }
        let values = items.compactMap(\.number)
        guard values.count == items.count, values.allSatisfy({ $0 == $0.rounded() && $0 >= 0 && $0 <= 16384 }) else { return nil }
        return values.map { Int($0) }
    }
    subscript(key: String) -> PhoneFlowValue? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { $0.0 == key }?.1
    }
    var keys: [String] { if case .map(let pairs) = self { pairs.map(\.0) } else { [] } }
}

extension PhoneFlow {
    public static let verbs = ["tap", "fill", "type", "press", "swipe", "scroll", "launch", "open", "install",
                               "expect", "expect-not", "wait", "screenshot"]

    public static func parse(_ text: String) throws -> PhoneFlow {
        var steps: [PhoneFlowStep] = []
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = index + 1
            var scanner = Scanner(raw, line: line)
            let content = try scanner.withoutComment().trimmingCharacters(in: .whitespaces)
            if content.isEmpty || content == "---" { continue }
            guard content.hasPrefix("- ") else { throw PhoneFlowError(line: line, message: "Each step starts with “- ”, like “- tap: \"Sign in\"”.") }
            let body = content.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard let colon = body.firstIndex(of: ":") else { throw PhoneFlowError(line: line, message: "Expected “verb: value”.") }
            let verb = body[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard verbs.contains(verb) else { throw PhoneFlowError(line: line, message: "Unknown step “\(verb)”. Steps: \(verbs.joined(separator: ", ")).") }
            scanner = Scanner(String(body[body.index(after: colon)...]), line: line)
            let value = try scanner.document()
            steps.append(PhoneFlowStep(line: line, source: body, kind: try step(verb, value, line: line)))
        }
        return PhoneFlow(steps: steps)
    }

    private static func step(_ verb: String, _ value: PhoneFlowValue, line: Int) throws -> PhoneFlowStep.Kind {
        func fail(_ message: String) -> PhoneFlowError { PhoneFlowError(line: line, message: message) }
        func allow(_ keys: Set<String>) throws {
            let unknown = value.keys.filter { !keys.contains($0) }
            if !unknown.isEmpty { throw fail("“\(verb)” does not take \(unknown.joined(separator: ", ")).") }
        }
        func selector() -> ElementSelector? {
            let selector = ElementSelector(identifier: value["id"]?.text, label: value["label"]?.text, role: value["role"]?.text)
            return selector.isEmpty ? nil : selector
        }
        func action(_ action: PhoneAction) throws -> PhoneFlowStep.Kind {
            do { try action.validate() } catch { throw fail(error.localizedDescription) }
            return .act(action)
        }
        func text() throws -> String {
            guard let text = value.text, !text.isEmpty else { throw fail("“\(verb)” needs text, like “- \(verb): \"…\"”.") }
            return text
        }
        switch verb {
        case "tap":
            if let points = value.integers { return try action(PhoneAction(kind: .tap, coordinates: points)) }
            if case .map = value {
                try allow(["id", "label", "role", "x", "y"])
                if let x = value["x"]?.number, let y = value["y"]?.number { return try action(PhoneAction(kind: .tap, coordinates: [Int(x), Int(y)])) }
                return try action(PhoneAction(kind: .tap, target: selector()))
            }
            return .tapText(try text())
        case "fill":
            try allow(["id", "label", "role", "text"])
            guard let target = selector(), let text = value["text"]?.text else { throw fail("fill needs {id: …, text: …} (or label instead of id).") }
            return try action(PhoneAction(kind: .fill, target: target, text: text))
        case "type": return try action(PhoneAction(kind: .type, text: try text()))
        case "press": return try action(PhoneAction(kind: .press, text: try text().lowercased()))
        case "launch": return try action(PhoneAction(kind: .launch, text: try text()))
        case "open": return try action(PhoneAction(kind: .open, text: try text()))
        case "install": return try action(PhoneAction(kind: .install, text: try text()))
        case "swipe":
            if let points = value.integers { return try action(PhoneAction(kind: .swipe, coordinates: points)) }
            try allow(["from", "to", "duration"])
            guard let from = value["from"]?.integers, let to = value["to"]?.integers, from.count == 2, to.count == 2 else {
                throw fail("swipe needs [x1, y1, x2, y2] or {from: [x, y], to: [x, y], duration: 0.3}.")
            }
            return try action(PhoneAction(kind: .swipe, coordinates: from + to, duration: value["duration"]?.number))
        case "scroll":
            if case .map = value {
                try allow(["direction", "id", "label", "role", "duration"])
                return try action(PhoneAction(kind: .scroll, target: selector(), direction: value["direction"]?.text?.lowercased(), duration: value["duration"]?.number))
            }
            return try action(PhoneAction(kind: .scroll, direction: try text().lowercased()))
        case "expect", "expect-not":
            let condition: PhoneWaitCondition, timeout: Double?
            if case .map = value {
                try allow(["text", "id", "app", "timeout"])
                condition = PhoneWaitCondition(text: value["text"]?.text, identifier: value["id"]?.text, app: value["app"]?.text, absent: verb == "expect-not")
                timeout = value["timeout"]?.number
            } else { condition = PhoneWaitCondition(text: try text(), absent: verb == "expect-not"); timeout = nil }
            do { try condition.validate() } catch { throw fail("\(verb) needs text, id or app.") }
            if let timeout, !(0...120).contains(timeout) { throw fail("timeout must be 0–120 seconds.") }
            return .expect(condition, timeout: timeout)
        case "wait":
            guard let seconds = value.number, (0...120).contains(seconds) else { throw fail("wait takes seconds, 0–120.") }
            return .pause(seconds)
        default: return .screenshot(try text())
        }
    }

    // MARK: Writing flows from recorded input

    /// Turns recorded input into a flow. Pauses longer than a second are kept, up to ten seconds.
    public static func render(_ entries: [PhoneActionLogEntry], header: String? = nil) -> String {
        var lines = header.map { $0.split(separator: "\n", omittingEmptySubsequences: false).map { "# " + $0 } } ?? []
        var previous: Date?
        for entry in entries where entry.outcome == "delivered" {
            if let previous {
                let gap = min(10, entry.at.timeIntervalSince(previous))
                if gap >= 1 { lines.append("- wait: \(String(format: "%.1f", gap))") }
            }
            previous = entry.at
            if let line = line(for: entry) { lines.append(line) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func quote(_ text: String) -> String {
        var out = "\""
        for character in text {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1, scalar.value < 0x20 || (0xF700...0xF8FF).contains(scalar.value) {
                    out += String(format: "\\u%04X", scalar.value)
                } else { out.append(character) }
            }
        }
        return out + "\""
    }

    private static func line(for entry: PhoneActionLogEntry) -> String? {
        let action = entry.action
        func named() -> String? {
            if let id = entry.target?.identifier ?? action.target?.identifier { return "id: \(quote(id))" }
            if let label = entry.target?.label ?? action.target?.label { return "label: \(quote(label))" }
            return nil
        }
        func points(_ values: ArraySlice<Int>) -> String { "[" + values.map(String.init).joined(separator: ", ") + "]" }
        switch action.kind {
        case .tap:
            if let name = named() { return "- tap: {\(name)}" }
            if let coordinates = action.coordinates { return "- tap: \(points(coordinates[...]))" }
            if let target = entry.target { return "- tap: \(points(target.bounds.center[...]))" }
            return nil
        case .fill:
            guard let name = named() else { return nil }
            if action.text == PhoneActionLog.redacted { return "- fill: {\(name), text: \"\"}  # secure field: its text was not recorded" }
            return "- fill: {\(name), text: \(quote(action.text ?? ""))}"
        case .type: return action.text.map { "- type: \(quote($0))" }
        case .press: return action.text.map { "- press: \($0.lowercased())" }
        case .launch, .open, .install: return action.text.map { "- \(action.kind.rawValue): \(quote($0))" }
        case .swipe:
            guard let c = action.coordinates, c.count == 4 else { return nil }
            if let duration = action.duration, abs(duration - 0.3) > 0.001 {
                return "- swipe: {from: \(points(c[0..<2])), to: \(points(c[2..<4])), duration: \(String(format: "%.2f", duration))}"
            }
            return "- swipe: \(points(c[...]))"
        case .scroll:
            guard let direction = action.direction else { return nil }
            if let name = named() { return "- scroll: {direction: \(direction), \(name)}" }
            return "- scroll: \(direction)"
        }
    }
}

/// Reads one line's value: quoted or plain scalars, `[a, b]` and `{key: value}`.
private struct Scanner {
    let characters: [Character]
    let line: Int
    var index = 0
    init(_ text: String, line: Int) { characters = Array(text); self.line = line }

    func fail(_ message: String) -> PhoneFlowError { PhoneFlowError(line: line, message: message) }

    /// The line without a trailing `# comment`, respecting quotes.
    func withoutComment() throws -> String {
        var quote: Character?, out = "", previous: Character = " "
        var i = 0
        while i < characters.count {
            let c = characters[i]
            if let open = quote {
                out.append(c)
                if c == "\\" && open == "\"", i + 1 < characters.count { out.append(characters[i + 1]); i += 2; continue }
                if c == open { quote = nil }
            } else if c == "\"" || c == "'" { quote = c; out.append(c) }
            else if c == "#" && (previous == " " || previous == "\t" || out.isEmpty) { break }
            else { out.append(c) }
            previous = c; i += 1
        }
        if quote != nil { throw fail("Unclosed quote.") }
        return out
    }

    mutating func document() throws -> PhoneFlowValue {
        skipSpaces()
        guard index < characters.count else { throw fail("Missing value after “:”.") }
        let value = try parseValue(inCollection: false)
        skipSpaces()
        guard index == characters.count else { throw fail("Unexpected text after the value.") }
        return value
    }
    private mutating func skipSpaces() { while index < characters.count, characters[index] == " " || characters[index] == "\t" { index += 1 } }
    private mutating func parseValue(inCollection: Bool) throws -> PhoneFlowValue {
        skipSpaces()
        guard index < characters.count else { throw fail("Missing value.") }
        switch characters[index] {
        case "[":
            index += 1; var items: [PhoneFlowValue] = []
            skipSpaces()
            if index < characters.count, characters[index] == "]" { index += 1; return .list([]) }
            while true {
                items.append(try parseValue(inCollection: true)); skipSpaces()
                guard index < characters.count else { throw fail("Unclosed “[”.") }
                if characters[index] == "," { index += 1; continue }
                if characters[index] == "]" { index += 1; return .list(items) }
                throw fail("Expected “,” or “]”.")
            }
        case "{":
            index += 1; var pairs: [(String, PhoneFlowValue)] = []
            skipSpaces()
            if index < characters.count, characters[index] == "}" { index += 1; return .map([]) }
            while true {
                skipSpaces()
                let key = try scalar(stops: [":"]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, index < characters.count, characters[index] == ":" else { throw fail("Expected “key: value” inside { }.") }
                index += 1
                if pairs.contains(where: { $0.0 == key }) { throw fail("“\(key)” appears twice.") }
                pairs.append((key, try parseValue(inCollection: true))); skipSpaces()
                guard index < characters.count else { throw fail("Unclosed “{”.") }
                if characters[index] == "," { index += 1; continue }
                if characters[index] == "}" { index += 1; return .map(pairs) }
                throw fail("Expected “,” or “}”.")
            }
        case "\"", "'": return .string(try quoted())
        default:
            let plain = try scalar(stops: inCollection ? [",", "]", "}"] : []).trimmingCharacters(in: .whitespaces)
            if let number = Double(plain), plain.range(of: "^-?[0-9]+(\\.[0-9]+)?$", options: .regularExpression) != nil { return .number(number) }
            return .string(plain)
        }
    }
    private mutating func scalar(stops: Set<Character>) throws -> String {
        if index < characters.count, characters[index] == "\"" || characters[index] == "'" { return try quoted() }
        var out = ""
        while index < characters.count, !stops.contains(characters[index]) { out.append(characters[index]); index += 1 }
        return out
    }
    private mutating func quoted() throws -> String {
        let open = characters[index]; index += 1
        var out = ""
        while index < characters.count {
            let c = characters[index]; index += 1
            if open == "'" {
                if c == "'" {
                    if index < characters.count, characters[index] == "'" { out.append("'"); index += 1; continue }
                    return out
                }
                out.append(c); continue
            }
            if c == "\"" { return out }
            if c == "\\" {
                guard index < characters.count else { break }
                let e = characters[index]; index += 1
                switch e {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "u":
                    guard index + 4 <= characters.count, let code = UInt32(String(characters[index..<index + 4]), radix: 16), let scalar = Unicode.Scalar(code) else { throw fail("Bad \\u escape.") }
                    out.unicodeScalars.append(scalar); index += 4
                default: throw fail("Unknown escape \\\(e).")
                }
                continue
            }
            out.append(c)
        }
        throw fail("Unclosed quote.")
    }
}
