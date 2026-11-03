import Foundation
import Darwin
import CryptoKit

/// Private local transport only. Device/WDA networking is owned by the platform adapters.
public enum PhoneAgentPaths {
    public static func root() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/terminal-phone-agent-\(getuid())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw AgentError(.notReady, "The phone session directory must be private and owned by this user.")
        }
        return root
    }
    public static func endpoint(phone: Phone, store: PhoneStore) throws -> URL {
        let key = store.root.standardizedFileURL.resolvingSymlinksInPath().path + "\n" + phone.udid.lowercased()
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return try root().appendingPathComponent(hash + ".sock")
    }
    /// Controllers from different registries must also exclude each other on the same device.
    public static func controlLock(phone: Phone) throws -> URL {
        try root().appendingPathComponent(phone.udid.lowercased() + ".control.lock")
    }
}

public final class PhoneAgentSocket: @unchecked Sendable {
    public static let maxPacket = 16 * 1024 * 1024
    private let descriptor: Int32
    private var ownsDescriptor = true
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { if ownsDescriptor { Darwin.close(descriptor) } }

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw AgentError(.notReady, "Session socket path is too long.") }
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
    private static func make() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentError(.notReady, "Cannot create the local phone session socket: \(String(cString: strerror(errno)))") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }
    public static func connect(_ path: String) throws -> PhoneAgentSocket {
        var address = try address(path)
        let fd = try make()
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { Darwin.close(fd); throw AgentError(.notReady, "The phone session is not running.") }
        let connection = PhoneAgentSocket(fd)
        try connection.checkPeer()
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        return connection
    }
    public static func listen(_ path: String) throws -> PhoneAgentSocket {
        var address = try address(path)
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw AgentError(.notReady, "Unexpected file at the session socket path.") }
            guard (try? connect(path)) == nil else { throw AgentError(.controllerBusy, "A phone session is already running.") }
            guard unlink(path) == 0 else { throw AgentError(.notReady, "Cannot remove the inactive session socket.") }
        }
        let fd = try make()
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd); throw AgentError(.notReady, "Cannot listen for local phone session requests.")
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        return PhoneAgentSocket(fd)
    }
    public func accept(timeout: Double = 1) throws -> PhoneAgentSocket? {
        var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let count = poll(&item, 1, Int32(timeout * 1000))
        if count == 0 || (count < 0 && errno == EINTR) { return nil }
        guard count > 0 else { throw AgentError(.disconnected, "The session listener closed.") }
        let fd = Darwin.accept(descriptor, nil, nil)
        if fd < 0, errno == EAGAIN { return nil }
        guard fd >= 0 else { throw AgentError(.disconnected, "Cannot accept a session request.") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC); _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        let connection = PhoneAgentSocket(fd); try connection.checkPeer(); return connection
    }
    private func checkPeer() throws {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0, uid == getuid() else {
            throw AgentError(.notReady, "The session peer belongs to another user.")
        }
    }
    public func peerPID() throws -> pid_t {
        var pid: pid_t = 0, length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 1 else {
            throw AgentError(.notReady, "Cannot identify the phone session process.")
        }
        return pid
    }
    public func cancel() { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
    public func peerHasClosed() -> Bool {
        var byte: UInt8 = 0
        let result = Darwin.recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return result == 0 || (result < 0 && ![EAGAIN, EWOULDBLOCK, EINTR].contains(errno))
    }
    private func ready(_ event: Int32, deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw AgentError(.disconnected, "The local session request timed out.") }
            var item = pollfd(fd: descriptor, events: Int16(event), revents: 0)
            let count = poll(&item, 1, Int32(min(remaining * 1000, 1000)))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw AgentError(.disconnected, "The local session connection failed.") }
            if count > 0 {
                if item.revents & Int16(event) != 0 { return }
                throw AgentError(.disconnected, "The local session connection ended.")
            }
        }
    }
    private func read(_ count: Int, deadline: Date) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(count, 65536))
        while result.count < count {
            try ready(POLLIN, deadline: deadline)
            let size = Darwin.recv(descriptor, &buffer, min(buffer.count, count - result.count), 0)
            if size < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard size > 0 else { throw AgentError(.disconnected, "The local session connection ended before replying.") }
            result.append(contentsOf: buffer.prefix(size))
        }
        return result
    }
    public func readPacket(timeout: Double = 240) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        let header = try read(4, deadline: deadline)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...Self.maxPacket).contains(length) else { throw AgentError(.invalidRequest, "Invalid session packet size.") }
        return try read(length, deadline: deadline)
    }
    public func writePacket(_ data: Data, timeout: Double = 10) throws {
        guard (1...Self.maxPacket).contains(data.count) else { throw AgentError(.invalidRequest, "The session packet is too large.") }
        var header = UInt32(data.count).bigEndian
        var packet = withUnsafeBytes(of: &header) { Data($0) }; packet.append(data)
        let deadline = Date().addingTimeInterval(timeout)
        try packet.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try ready(POLLOUT, deadline: deadline)
                let size = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if size < 0 && [EINTR, EAGAIN].contains(errno) { continue }
                guard size > 0 else { throw AgentError(.disconnected, "Cannot write to the local session.") }
                offset += size
            }
        }
    }
}
