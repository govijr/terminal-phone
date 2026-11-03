import Foundation

public enum TerminalEvent: Equatable {
    case text(String)
    case key(String)
    case mouse(button: Int, column: Int, row: Int, released: Bool)
    case quit
}

public struct TerminalInput {
    private var bytes: [UInt8] = []
    public init() {}
    public mutating func feed(_ input: [UInt8], flushEscape: Bool = false) -> [TerminalEvent] {
        bytes += input
        var events: [TerminalEvent] = []
        while !bytes.isEmpty {
            if bytes[0] == 29 { bytes.removeFirst(); events.append(.quit); continue }
            if bytes[0] == 27 {
                if bytes.count == 1 {
                    if flushEscape { bytes.removeFirst(); events.append(.key("escape")) }
                    break
                }
                if bytes[1] == 91 {
                    guard let end = bytes.indices.dropFirst(2).first(where: { (64...126).contains(bytes[$0]) }) else {
                        if bytes.count > 128 { bytes.removeAll() }
                        break
                    }
                    let sequence = String(decoding: bytes[0...end], as: UTF8.self)
                    bytes.removeFirst(end + 1)
                    let keys = ["\u{1b}[A":"up", "\u{1b}[B":"down", "\u{1b}[C":"right", "\u{1b}[D":"left", "\u{1b}[H":"home", "\u{1b}[F":"end", "\u{1b}[3~":"delete", "\u{1b}[5~":"pageup", "\u{1b}[6~":"pagedown", "\u{1b}[Z":"shift+tab"]
                    if let key = keys[sequence] { events.append(.key(key)) }
                    else if sequence.hasPrefix("\u{1b}[<"), sequence.hasSuffix("M") || sequence.hasSuffix("m") {
                        let parts = sequence.dropFirst(3).dropLast().split(separator: ";").compactMap { Int($0) }
                        if parts.count == 3, parts[1] > 0, parts[2] > 0 {
                            events.append(.mouse(button: parts[0], column: parts[1], row: parts[2], released: sequence.hasSuffix("m")))
                        }
                    }
                    continue
                }
                bytes.removeFirst(); events.append(.key("escape")); continue
            }
            let first = bytes[0]
            if first < 32 || first == 127 {
                bytes.removeFirst()
                if first == 13 || first == 10 { events.append(.key("return")) }
                else if first == 9 { events.append(.key("tab")) }
                else if first == 127 || first == 8 { events.append(.key("backspace")) }
                else if (1...26).contains(first) { events.append(.key("ctrl+" + String(UnicodeScalar(Int(first) + 96)!))) }
                continue
            }
            let length = first < 128 ? 1 : first >= 0xC2 && first <= 0xDF ? 2 : first <= 0xEF && first >= 0xE0 ? 3 : first >= 0xF0 && first <= 0xF4 ? 4 : 0
            guard length > 0 else { bytes.removeFirst(); continue }
            guard bytes.count >= length else { break }
            let fragment = Array(bytes.prefix(length))
            if let text = String(bytes: fragment, encoding: .utf8) { events.append(.text(text)); bytes.removeFirst(length) }
            else { bytes.removeFirst() }
        }
        return events
    }
}
