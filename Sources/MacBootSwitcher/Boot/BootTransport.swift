import Foundation
import Darwin

/// IPC 只传固定结构；密码通过经对端 UID 核验的本次 socket 传输，不落普通文件。
struct BootRequest: Codable, Sendable {
    let target: BootTarget
    let ownerUsername: String
    var ownerPassword: String
    var isValid: Bool {
        target.isValid && !ownerUsername.isEmpty && ownerUsername.utf8.count <= 255 &&
        !ownerUsername.contains("\0") && !ownerUsername.contains("\n") &&
        !ownerPassword.isEmpty && ownerPassword.utf8.count <= 4096 &&
        !ownerPassword.contains("\0") && !ownerPassword.contains("\n")
    }
}

enum BootProgress: String, Codable, Sendable {
    case checkingTarget
    case awaitingAuthorization
    case recheckingTarget
    case settingBoot
}

struct BootMessage: Codable, Sendable {
    var step: BootProgress?
    var outcome: String?
    var code: Int32?
}

enum TransportError: Error { case invalid, timeout, disconnected }

final class BootConnection: @unchecked Sendable {
    let fd: Int32
    private var pending = Data()
    init(fd: Int32) {
        self.fd = fd
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
    }
    deinit { close(fd) }
    func peerUID() throws -> uid_t {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { throw TransportError.invalid }
        return uid
    }
    func send<T: Encodable>(_ value: T) throws {
        var bytes = try JSONEncoder().encode(value)
        bytes.append(10)
        guard bytes.count <= 16_384 else { throw TransportError.invalid }
        var offset = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while offset < bytes.count {
            try wait(Int16(POLLOUT), deadline: deadline)
            let count = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0) }
            if count > 0 { offset += count }
            else if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            else { throw TransportError.disconnected }
        }
    }
    func receive<T: Decodable>(_ type: T.Type, timeout: TimeInterval) throws -> T {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            if let end = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: end)
                pending.removeSubrange(...end)
                return try JSONDecoder().decode(type, from: line)
            }
            guard pending.count < 16_384 else { throw TransportError.invalid }
            try wait(Int16(POLLIN), deadline: deadline)
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &bytes, bytes.count)
            if count > 0 { pending.append(contentsOf: bytes.prefix(count)) }
            else if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            else { throw TransportError.disconnected }
        }
    }
    private func wait(_ events: Int16, deadline: TimeInterval) throws {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        while true {
            let left = deadline - ProcessInfo.processInfo.systemUptime
            guard left > 0 else { throw TransportError.timeout }
            let result = poll(&descriptor, 1, Int32(min(left * 1000, 1000)))
            if result > 0 { return }
            if result < 0 && errno != EINTR { throw TransportError.disconnected }
        }
    }
}

final class BootSession: @unchecked Sendable {
    let directory: URL
    let socketPath: String
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var active: BootConnection?

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("MBS-\(UUID().uuidString)")
        socketPath = directory.appendingPathComponent("endpoint").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { try? FileManager.default.removeItem(at: directory); throw TransportError.invalid }
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
        var address = try Self.address(socketPath)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, chmod(socketPath, 0o600) == 0, listen(listener, 1) == 0 else {
            close(listener); try? FileManager.default.removeItem(at: directory); throw TransportError.invalid
        }
    }
    deinit { close(listener); try? FileManager.default.removeItem(at: directory) }
    func stop() { lock.withLock { stopped = true } }
    func abort() { lock.withLock { stopped = true; if let active { shutdown(active.fd, SHUT_RDWR) } } }
    func acceptRoot(timeout: TimeInterval = 300) throws -> BootConnection {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !lock.withLock({ stopped }) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw TransportError.timeout }
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptor, 1, 100)
            let client = accept(listener, nil, nil)
            if client < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw TransportError.disconnected }
            let connection = BootConnection(fd: client)
            guard try connection.peerUID() == 0 else { continue }
            guard lock.withLock({ if stopped { return false }; active = connection; return true }) else { throw TransportError.disconnected }
            return connection
        }
        throw TransportError.disconnected
    }
    static func connect(_ path: String) throws -> BootConnection {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError.invalid }
        var address = try address(path)
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard status == 0 else { close(fd); throw TransportError.disconnected }
        return BootConnection(fd: fd)
    }
    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw TransportError.invalid }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes) }
        return address
    }
}

/// 固定 inode 的锁归执行侧持有，不随 UI 退出释放。
final class BootOperationLock {
    private let fd: Int32
    init(path: String = "/private/var/run/MacBootSwitcher.operation.lock", owner: uid_t = 0) throws {
        fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TransportError.invalid }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == owner,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1,
              metadata.st_mode & 0o077 == 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw TransportError.invalid
        }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}
