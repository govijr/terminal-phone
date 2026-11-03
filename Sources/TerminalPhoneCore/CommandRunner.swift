import Foundation
import Darwin
import TerminalMacCore

public struct CommandResult {
    public let output: Data
    public let error: String
    public let status: Int32
}

private final class ProcessDeadline: @unchecked Sendable {
    let lock = NSLock()
    var finished = false
    var expired = false
}

public enum CommandRunner {
    public static func executable(_ name: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        if name == "idb", let override = environment["TERMINAL_PHONE_IDB"] {
            return override.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        if name == "idb_companion", let override = environment["TERMINAL_PHONE_COMPANION"] {
            return override.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        let managed: String? = name == "idb" ? "idb-venv/bin/idb" : name == "idb_companion" ? "companion/idb_companion" : nil
        if let managed {
            let path = PhoneDependencyPaths.root.appendingPathComponent(managed).path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if name == "idb", let executable = Bundle.main.executableURL {
            let local = executable.resolvingSymlinksInPath().deletingLastPathComponent()
                .appendingPathComponent("dependencies/idb-venv/bin/idb").path
            if FileManager.default.isExecutableFile(atPath: local) { return local }
        }
        let search = (environment["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for directory in search.split(separator: ":") {
            let path = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60) async throws -> CommandResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-phone-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outURL = directory.appendingPathComponent("stdout")
        let errURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out; process.standardError = err
        let deadline = ProcessDeadline()
        try process.run()
        // Files avoid pipe-buffer deadlocks for large screenshots and accessibility trees.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            deadline.lock.lock(); defer { deadline.lock.unlock() }
            guard !deadline.finished, process.isRunning else { return }
            deadline.expired = true
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                deadline.lock.lock(); defer { deadline.lock.unlock() }
                if !deadline.finished, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { process.waitUntilExit(); continuation.resume() }
        }
        let expired = deadline.lock.withLock {
            deadline.finished = true
            return deadline.expired
        }
        if expired { throw Failure("\(URL(fileURLWithPath: executable).lastPathComponent) timed out after \(Int(timeout)) seconds") }
        return CommandResult(output: try Data(contentsOf: outURL), error: String(decoding: try Data(contentsOf: errURL), as: UTF8.self), status: process.terminationStatus)
    }

    public static func checked(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60) async throws -> Data {
        let result = try await run(executable, arguments, timeout: timeout)
        guard result.status == 0 else {
            let detail = result.error.isEmpty ? String(decoding: result.output.prefix(4096), as: UTF8.self) : String(result.error.prefix(4096))
            throw Failure("\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(result.status)): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.output
    }
}
