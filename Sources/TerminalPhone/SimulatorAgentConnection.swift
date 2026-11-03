import Foundation
import Darwin
import TerminalPhoneCore
import TerminalMacCore

/// Agent traffic has its own idb connection and no video producer to delay observations.
@MainActor
final class SimulatorAgentConnection {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private let cli: PhoneCLI
    private let phone: Phone
    private let logName: String
    init(cli: PhoneCLI, phone: Phone, logName: String = "agent-worker.log") { self.cli = cli; self.phone = phone; self.logName = logName }

    private func start() async throws {
        if process?.isRunning == true { return }
        close()
        guard let idb = cli.idb else { throw AgentError(.notReady, "Install idb using scripts/setup-phone-automation.sh.") }
        let bin = URL(fileURLWithPath: idb).resolvingSymlinksInPath().deletingLastPathComponent()
        guard let python = ["python3", "python"].map({ bin.appendingPathComponent($0).path }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AgentError(.notReady, "Cannot locate idb's Python runtime. Run scripts/setup-phone-automation.sh.")
        }
        let worker = Bundle.main.executableURL!.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("resources/phone-agent-worker.py")
        guard FileManager.default.fileExists(atPath: worker.path) else { throw AgentError(.notReady, "The agent helper is missing. Run scripts/build-phone.sh.") }
        let socket = try await PhoneCompanion.socketFor(phone, store: cli.store)
        let stdin = Pipe(), stdout = Pipe(), child = Process()
        child.executableURL = URL(fileURLWithPath: python)
        child.arguments = ["-u", worker.path, "--socket", socket, "--udid", phone.udid]
        child.standardInput = stdin; child.standardOutput = stdout
        let path = try cli.store.directory(phone.name).appendingPathComponent(logName)
        FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: path); defer { try? log.close() }
        child.standardError = log
        try child.run(); process = child; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
    }

    func call(_ action: String, values: [String] = [], text: String? = nil, duration: Double = 0.3) async throws -> [String: Any] {
        try await start()
        let id = UUID().uuidString
        var request: [String: Any] = ["id": id, "action": action, "values": values, "duration": duration]
        if let text { request["text"] = text }
        let payload = try JSONSerialization.data(withJSONObject: request) + Data([10])
        guard let input, let output, let process else { throw AgentError(.disconnected, "The simulator agent helper ended.") }
        do {
            let reply: Data = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    do {
                        try input.write(contentsOf: payload)
                        let deadline = Date().addingTimeInterval(65)
                        func read(_ count: Int) throws -> Data {
                            var data = Data()
                            while data.count < count {
                                let remaining = deadline.timeIntervalSinceNow
                                guard remaining > 0 else { throw AgentError(.disconnected, "The simulator helper timed out.") }
                                var item = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
                                let ready = poll(&item, 1, Int32(min(remaining * 1000, 1000)))
                                if ready < 0 && errno == EINTR { continue }
                                guard ready >= 0 else { throw AgentError(.disconnected, "The simulator helper connection failed.") }
                                if ready == 0 { continue }
                                guard let bytes = try output.read(upToCount: min(65536, count - data.count)), !bytes.isEmpty else {
                                    throw AgentError(.disconnected, "The simulator agent helper ended. Check agent-worker.log.")
                                }
                                data.append(bytes)
                            }
                            return data
                        }
                        let size = try read(4).reduce(0) { $0 << 8 | Int($1) }
                        guard (1...PhoneAgentSocket.maxPacket).contains(size) else { throw AgentError(.disconnected, "Invalid simulator helper reply.") }
                        continuation.resume(returning: try read(size))
                    } catch {
                        if process.isRunning { process.terminate() }
                        continuation.resume(throwing: error)
                    }
                }
            }
            guard let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any], object["id"] as? String == id else {
                throw AgentError(.disconnected, "The simulator helper returned an unrelated reply.")
            }
            guard object["ok"] as? Bool == true else { throw AgentError(.backendUnavailable, object["error"] as? String ?? "Simulator operation failed.") }
            return object["result"] as? [String: Any] ?? [:]
        } catch { close(); throw error }
    }
    func close() {
        try? input?.close(); input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil; output = nil
    }
}
