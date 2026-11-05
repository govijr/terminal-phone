import Foundation

/// Runs a log stream in the background and keeps its most recent lines for the viewer's logs panel.
final class PhoneLogTail: @unchecked Sendable {
    struct Line: Equatable { let time: String; let level: Character?; let text: String }
    private let lock = NSLock()
    private let process = Process()
    private var partial = Data()
    private var stored: [Line] = []
    private var count = 0
    private var ended: String?
    static let capacity = 500

    init(executable: String, arguments: [String]) throws {
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.receive(data)
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.lock.withLock { if self.ended == nil { self.ended = "Log stream ended (status \(process.terminationStatus))" } }
        }
        try process.run()
    }

    /// The newest lines, oldest first, and a counter that changes whenever lines arrive.
    var snapshot: (lines: [Line], version: Int, ended: String?) { lock.withLock { (stored, count, ended) } }

    func stop() {
        lock.withLock { ended = ended ?? "" }
        if process.isRunning { process.terminate() }
    }

    private func receive(_ data: Data) {
        lock.withLock {
            partial.append(data)
            while let newline = partial.firstIndex(of: 10) {
                let line = String(decoding: partial[partial.startIndex..<newline], as: UTF8.self)
                partial.removeSubrange(partial.startIndex...newline)
                if let parsed = Self.parse(line) { stored.append(parsed); count += 1 }
            }
            if stored.count > Self.capacity { stored.removeFirst(stored.count - Self.capacity) }
        }
    }

    /// `log stream --style compact` lines look like `2026-11-05 01:03:10.659 I  Hello[99037:58e128] message`.
    /// The date is dropped; the level letter colours the line. Tool chatter is skipped.
    static func parse(_ raw: String) -> Line? {
        let line = raw.replacingOccurrences(of: "\u{1b}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\t", with: "  ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("getpwuid_r"), !line.hasPrefix("Filtering the log data"), !line.hasPrefix("Timestamp ") else { return nil }
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        if parts.count == 4, parts[0].range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil,
           parts[1].range(of: "^\\d{2}:\\d{2}:\\d{2}", options: .regularExpression) != nil, parts[2].count <= 2 {
            return Line(time: String(parts[1].prefix(12)), level: parts[2].first, text: String(parts[3]).trimmingCharacters(in: .whitespaces))
        }
        return Line(time: "", level: nil, text: line)
    }
}
