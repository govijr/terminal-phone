import Foundation
import Darwin

public final class FileLock {
    private let fd: Int32
    public init(_ url: URL) throws {
        fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure("Cannot open lock: \(url.path)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw Failure("Another terminal-mac operation is already using \(url.lastPathComponent). Wait for it to finish, then retry.")
        }
    }
    deinit { close(fd) }
}

public enum GuestReadiness: String {
    case unavailable, permissions, ready
    public init(_ values: [String: String]?) {
        guard let values else { self = .unavailable; return }
        self = values["screenRecording"] == "true" && values["accessibility"] == "true" ? .ready : .permissions
    }
}

public struct SetupPlan: Codable {
    public let name: String
    public let steps: [String]
    public init(name: String, machine: Machine?, hasLocalImage: Bool) {
        self.name = name
        var steps: [String] = []
        if machine?.installed != true {
            if !hasLocalImage { steps.append("download-or-reuse-apple-restore-image") }
            steps.append(machine == nil ? "install-macos" : "retry-incomplete-installation")
        }
        steps += ["start-or-resume-vm", "check-guest-helper-and-permissions", "open-terminal-view-if-supported"]
        self.steps = steps
    }
}
