import Foundation
import Darwin
import TerminalMacCore
import TerminalPhoneCore

@MainActor
enum PhoneCompanion {
    static func socketFor(_ phone: Phone, store: PhoneStore) async throws -> String {
        guard let executable = CommandRunner.executable("idb_companion") else { throw Failure("idb_companion is missing; run scripts/setup-phone-automation.sh") }
        let root = URL(fileURLWithPath: "/tmp/terminal-phone-\(getuid())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0 else {
            throw Failure("Companion socket directory must be a private directory owned by this user: \(root.path)")
        }
        let path = root.appendingPathComponent("\(phone.udid).sock").path
        let lock = try FileLock(root.appendingPathComponent("\(phone.udid).lock"))
        defer { withExtendedLifetime(lock) {} }
        if listening(path) { return path }
        if FileManager.default.fileExists(atPath: path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType == .typeSocket else { throw Failure("Unexpected file at companion socket path") }
            try FileManager.default.removeItem(atPath: path)
        }
        let logURL = try store.directory(phone.name).appendingPathComponent("automation.log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        try log.seekToEnd()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--udid", phone.udid, "--grpc-domain-sock", path, "--terminate-offline", "1", "--idle-shutdown-time", "600", "--log-level", "info"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log; process.standardError = log
        try process.run()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if listening(path) { return path }
            if !process.isRunning { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning { process.terminate() }
        throw Failure("Simulator automation did not become ready. Details: \(logURL.path)")
    }

    private static func listening(_ path: String) -> Bool {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: bytes) }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }
}
