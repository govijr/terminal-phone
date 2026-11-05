import Foundation
import Darwin

public final class FileLock {
    private let fd: Int32
    public init(_ url: URL) throws {
        fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure("Cannot open lock: \(url.path)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw Failure("Another terminal-phone operation is already using \(url.lastPathComponent). Wait for it to finish, then retry.")
        }
    }
    deinit { close(fd) }
}
