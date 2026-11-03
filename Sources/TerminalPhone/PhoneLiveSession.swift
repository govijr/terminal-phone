import Foundation
import TerminalMacCore
import TerminalPhoneCore

@MainActor
final class PhoneLiveSession {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    var onEvent: (([String: Any]) -> Void)?
    var onFailure: ((String) -> Void)?
    private var stopped = false

    /// `frames` runs on the reader thread, so video never waits for the UI loop.
    func start(cli: PhoneCLI, phone: Phone, scale: Double, streamScale: Double, frames: @escaping @Sendable (Data) -> Void) async throws {
        guard let idb = cli.idb else { throw Failure("Install idb to use the live viewer") }
        let bin = URL(fileURLWithPath: idb).resolvingSymlinksInPath().deletingLastPathComponent()
        guard let python = ["python3", "python"].map({ bin.appendingPathComponent($0).path }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw Failure("Cannot locate idb's Python runtime. Run scripts/setup-phone-automation.sh")
        }
        let executable = Bundle.main.executableURL!.resolvingSymlinksInPath()
        let worker = executable.deletingLastPathComponent().appendingPathComponent("resources/phone-viewer-worker.py")
        guard FileManager.default.fileExists(atPath: worker.path) else { throw Failure("Live viewer helper is missing. Rebuild with scripts/build-phone.sh") }
        let socket = try await PhoneCompanion.socketFor(phone, store: cli.store)
        let stdout = Pipe(), stdin = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: python)
        child.arguments = ["-u", worker.path, "--socket", socket, "--udid", phone.udid, "--scale", String(scale), "--stream-scale", String(streamScale), "--fps", "30"]
        child.standardOutput = stdout; child.standardInput = stdin
        let logURL = try cli.store.directory(phone.name).appendingPathComponent("viewer.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: logURL)
        child.standardError = log
        try child.run(); try? log.close()
        process = child; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        let reader = stdout.fileHandleForReading
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            func read(_ count: Int) throws -> Data? {
                var result = Data()
                while result.count < count {
                    guard let chunk = try reader.read(upToCount: count - result.count), !chunk.isEmpty else { return nil }
                    result.append(chunk)
                }
                return result
            }
            do {
                while let header = try read(4) {
                    let length = header.reduce(0) { $0 << 8 | Int($1) }
                    guard (1...16 * 1024 * 1024).contains(length), let packet = try read(length) else { throw Failure("Invalid live viewer packet") }
                    if packet[0] == 1 {
                        frames(Data(packet.dropFirst()))
                    } else if packet[0] == 2, let event = try JSONSerialization.jsonObject(with: packet.dropFirst()) as? [String: Any] {
                        Task { @MainActor [weak self] in if self?.stopped == false { self?.onEvent?(event) } }
                    }
                }
                Task { @MainActor [weak self] in if self?.stopped == false { self?.onFailure?("Live connection ended. See \(logURL.path)") } }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor [weak self] in if self?.stopped == false { self?.onFailure?(message) } }
            }
        }
    }
    func send(_ request: [String: Any]) throws {
        guard let input else { throw Failure("Live input is disconnected") }
        try input.write(contentsOf: JSONSerialization.data(withJSONObject: request) + Data([10]))
    }
    func stop() {
        stopped = true
        try? input?.close(); input = nil
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { process.interrupt() } }
        }
        // The reader finishes once the helper exits; don't race a close against its read.
        process = nil
    }
}
