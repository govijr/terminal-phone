import Foundation
import Darwin
import TerminalMacCore
import TerminalPhoneCore

private final class PhoneRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: PhoneAgentSocket?
    private var cancelled = false
    func attach(_ socket: PhoneAgentSocket) throws {
        try lock.withLock {
            guard !cancelled else { socket.cancel(); throw CancellationError() }
            self.socket = socket
        }
    }
    func cancel() { lock.withLock { cancelled = true; socket?.cancel() } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

@MainActor
enum PhoneAgentClient {
    private static var verifiedHosts: [String: pid_t] = [:]
    static func request(cli: PhoneCLI, name: String, request: PhoneAgentRequest, start: Bool = true) async throws -> PhoneAgentReply {
        try Task.checkCancellation()
        try request.validate()
        let phone = try cli.store.load(name)
        let endpoint = try PhoneAgentPaths.endpoint(phone: phone, store: cli.store)
        if (try? PhoneAgentSocket.connect(endpoint.path)) == nil {
            guard start else { throw AgentError(.notReady, "No agent session is running for '\(name)'.") }
            try await launch(cli: cli, phone: phone, endpoint: endpoint)
        }
        try await ensureCompatible(cli: cli, phone: phone, endpoint: endpoint)
        try Task.checkCancellation()
        let payload = try PhoneAgentCoding.encoder().encode(request)
        let cancellation = PhoneRequestCancellation()
        return try await withTaskCancellationHandler(operation: {
          try await Task.detached {
            let socket = try PhoneAgentSocket.connect(endpoint.path)
            try cancellation.attach(socket)
            do {
                try socket.writePacket(payload)
                let data = try socket.readPacket(timeout: 420)
                let reply = try PhoneAgentCoding.decoder().decode(PhoneAgentReply.self, from: data)
                guard reply.id == request.id else { throw AgentError(.disconnected, "The session returned an unrelated reply.") }
                return reply
            } catch {
                if cancellation.isCancelled { throw CancellationError() }
                if request.operation == .act || request.operation == .input {
                    throw AgentError(.actionOutcomeUnknown, "The session ended before the action result was received: \(error.localizedDescription)",
                                     recovery: "The input may have reached iOS. Observe before deciding what to do next; do not replay it automatically.")
                }
                throw error
            }
          }.value
        }, onCancel: { cancellation.cancel() })
    }

    private static func ensureCompatible(cli: PhoneCLI, phone: Phone, endpoint: URL) async throws {
        let pid = try PhoneAgentSocket.connect(endpoint.path).peerPID()
        if verifiedHosts[endpoint.path] == pid { return }
        let probe = PhoneAgentRequest(operation: .status, includeImage: false)
        let data = try PhoneAgentCoding.encoder().encode(probe)
        let compatible = (try? await Task.detached {
            let socket = try PhoneAgentSocket.connect(endpoint.path)
            try socket.writePacket(data)
            let reply = try PhoneAgentCoding.decoder().decode(PhoneAgentReply.self, from: socket.readPacket(timeout: 2))
            return reply.schemaVersion == PhoneAgentAPI.version
        }.value) ?? false
        if !compatible {
            _ = try await stop(cli: cli, name: phone.name)
            try await launch(cli: cli, phone: phone, endpoint: endpoint)
        }
        verifiedHosts[endpoint.path] = try PhoneAgentSocket.connect(endpoint.path).peerPID()
    }

    private static func launch(cli: PhoneCLI, phone: Phone, endpoint: URL) async throws {
        let startup = endpoint.deletingPathExtension().appendingPathExtension("startup.lock")
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if (try? PhoneAgentSocket.connect(endpoint.path)) != nil { return }
            if let lock = try? FileLock(startup) {
                defer { withExtendedLifetime(lock) {} }
                if (try? PhoneAgentSocket.connect(endpoint.path)) != nil { return }
                let logURL = try cli.store.directory(phone.name).appendingPathComponent("agent-session.log")
                FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                let log = try FileHandle(forWritingTo: logURL); defer { try? log.close() }
                let child = Process()
                child.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
                child.arguments = [Bundle.main.executableURL!.resolvingSymlinksInPath().path, "_session-host", phone.name]
                var environment = ProcessInfo.processInfo.environment
                environment["TERMINAL_PHONE_HOME"] = cli.store.root.path
                child.environment = environment
                child.standardInput = FileHandle.nullDevice; child.standardOutput = log; child.standardError = log
                try child.run()
                while Date() < deadline {
                    if (try? PhoneAgentSocket.connect(endpoint.path)) != nil { return }
                    guard child.isRunning else { throw AgentError(.notReady, "The phone session could not start. See \(logURL.path).") }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                throw AgentError(.notReady, "The phone session did not start within 15 seconds. See \(logURL.path).")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw AgentError(.notReady, "Another process is starting this phone session. Retry shortly.")
    }

    /// Identify the connected peer, rather than trusting a stale PID file or signalling a process name.
    static func stop(cli: PhoneCLI, name: String) async throws -> Bool {
        let phone = try cli.store.load(name)
        let endpoint = try PhoneAgentPaths.endpoint(phone: phone, store: cli.store)
        guard let socket = try? PhoneAgentSocket.connect(endpoint.path) else { return false }
        let pid = try socket.peerPID()
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let expected = Bundle.main.executableURL!.resolvingSymlinksInPath().path
        let actual = String(cString: buffer)
        guard length > 0, actual == expected || PhoneRuntimeRegistry.paths().contains(actual) else { throw AgentError(.notReady, "The socket peer is not a verified terminal-phone installation.") }
        guard kill(pid, SIGTERM) == 0 else { throw AgentError(.notReady, "Cannot stop the phone session.") }
        for _ in 0..<40 {
            if (try? PhoneAgentSocket.connect(endpoint.path)) == nil { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw AgentError(.notReady, "The phone session has not stopped yet.")
    }
}

@MainActor
enum PhoneAgentHost {
    static func run(cli: PhoneCLI, name: String) async throws {
        let phone = try cli.store.load(name)
        let endpoint = try PhoneAgentPaths.endpoint(phone: phone, store: cli.store)
        let lock = try FileLock(endpoint.deletingPathExtension().appendingPathExtension("host.lock"))
        defer { withExtendedLifetime(lock) {} }
        let listener = try PhoneAgentSocket.listen(endpoint.path)
        defer { try? FileManager.default.removeItem(at: endpoint) }
        let backend = PhoneAgentBackends.make(cli: cli, phone: phone)
        let session = PhoneAgentSession(backend: backend,
                                       artifacts: try cli.store.directory(name).appendingPathComponent("observations"),
                                       inputAllowed: {
            let saved = try cli.store.load(name)
            guard saved.udid == phone.udid else { throw AgentError(.notReady, "The phone registration changed. Stop the session and reconnect.") }
            return saved.acceptsInput
        }, acquireControl: { try FileLock(PhoneAgentPaths.controlLock(phone: phone)) })
        defer { session.close() }
        let signals = [SIGINT, SIGTERM, SIGHUP]
        let sources = signals.map { number -> DispatchSourceSignal in
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                session.close()
                try? FileManager.default.removeItem(at: endpoint)
                exit(0)
            }
            source.resume(); return source
        }
        defer { sources.forEach { $0.cancel() } }
        var lastActivity = Date()
        let agentQueue = PhoneWorkQueue()
        var connections: [UUID: Task<Void, Never>] = [:]
        defer { connections.values.forEach { $0.cancel() } }
        while !connections.isEmpty || Date().timeIntervalSince(lastActivity) < 600 {
            let connection = try await Task.detached { try listener.accept() }.value
            guard let connection else { continue }
            guard connections.count < 32 else { continue }
            let connectionId = UUID()
            connections[connectionId] = Task { @MainActor in
              defer { connections.removeValue(forKey: connectionId) }
              do {
                let data = try await Task.detached { try connection.readPacket(timeout: 5) }.value
                guard data.count <= 256 * 1024 else { throw AgentError(.invalidRequest, "Session requests are limited to 256 KiB.") }
                let request = try PhoneAgentCoding.decoder().decode(PhoneAgentRequest.self, from: data)
                if connection.peerHasClosed() { return }
                lastActivity = Date()
                let reply: PhoneAgentReply
                if [.input, .status, .capabilities].contains(request.operation) {
                    reply = await session.handle(request, isCancelled: { connection.peerHasClosed() })
                } else {
                    reply = await agentQueue.run {
                        await session.handle(request, isCancelled: { connection.peerHasClosed() })
                    }
                }
                let result = try PhoneAgentCoding.encoder().encode(reply)
                try await Task.detached { try connection.writePacket(result) }.value
            } catch {
                // Connect-only probes and clients that leave never cause input to be replayed.
                return
              }
            }
        }
    }
}
