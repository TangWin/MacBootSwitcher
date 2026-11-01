import Foundation
import Darwin

struct CommandResult: Sendable {
    enum Termination: Sendable { case exit, signal }
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var termination: Termination = .exit
}

protocol CommandExecuting: Sendable {
    func run(path: String, arguments: [String], stdinData: Data?, timeout: TimeInterval) async throws -> CommandResult
}

extension CommandExecuting {
    func run(path: String, arguments: [String], stdinData: Data? = nil, timeout: TimeInterval = 30) async throws -> CommandResult {
        try await run(path: path, arguments: arguments, stdinData: stdinData, timeout: timeout)
    }
}

enum CommandError: Error, LocalizedError {
    case timeout
    case cancelled
    case processCreationFailed(String)
    var errorDescription: String? {
        switch self {
        case .timeout: return "系统操作等待超时"
        case .cancelled: return "系统操作已中断"
        case .processCreationFailed: return "无法启动系统工具"
        }
    }
}

/// 每条命令使用独立进程组；管道从启动起排空，不在 Swift 任务中阻塞等待。
final class ProcessExecutor: CommandExecuting, @unchecked Sendable {
    func run(path: String, arguments: [String], stdinData: Data?, timeout: TimeInterval) async throws -> CommandResult {
        let operation = ProcessOperation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start(path: path, arguments: arguments, input: stdinData, timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            operation.cancel()
        }
    }
}

private final class ProcessOperation: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacBootSwitcher.process")
    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var pid: pid_t = 0
    private var descriptors: [Int32] = []
    private var readers: [Int32: DispatchSourceRead] = [:]
    private var writer: DispatchSourceWrite?
    private var writerDescriptor: Int32?
    private var timer: DispatchSourceTimer?
    private var output = [Data(), Data()]
    private var input = Data()
    private var inputOffset = 0
    private var interruption: CommandError?
    private var finished = false
    private var cancelled = false
    // 防止错误工具产生无限输出，达到上限后仍排空而不继续保存。
    private let outputLimit = 8 * 1024 * 1024

    func start(path: String, arguments: [String], input: Data?, timeout: TimeInterval, continuation: CheckedContinuation<CommandResult, Error>) {
        queue.async {
            self.continuation = continuation
            guard !self.cancelled else { self.finish(.failure(CommandError.cancelled)); return }
            guard path.hasPrefix("/"), !path.contains("\0"), arguments.allSatisfy({ !$0.contains("\0") }), timeout > 0 else {
                self.finish(.failure(CommandError.processCreationFailed("参数无效"))); return
            }
            var out = [Int32](repeating: 0, count: 2)
            var err = out
            var incoming = out
            guard pipe(&out) == 0 else { self.finish(.failure(CommandError.processCreationFailed("pipe"))); return }
            self.descriptors = out
            guard pipe(&err) == 0 else { self.finish(.failure(CommandError.processCreationFailed("pipe"))); return }
            self.descriptors += err
            guard pipe(&incoming) == 0 else { self.finish(.failure(CommandError.processCreationFailed("pipe"))); return }
            self.descriptors += incoming
            // 测试宿主或调用环境可能关闭标准描述符，避免后续 close 动作关闭 dup2 的目标。
            for index in self.descriptors.indices where self.descriptors[index] <= STDERR_FILENO {
                let old = self.descriptors[index]
                let replacement = fcntl(old, F_DUPFD_CLOEXEC, 3)
                guard replacement >= 0 else { self.finish(.failure(CommandError.processCreationFailed("descriptor"))); return }
                self.descriptors[index] = replacement
                close(old)
            }
            out = Array(self.descriptors[0..<2]); err = Array(self.descriptors[2..<4]); incoming = Array(self.descriptors[4..<6])
            for fd in self.descriptors { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            var actions: posix_spawn_file_actions_t?
            var attrs: posix_spawnattr_t?
            posix_spawn_file_actions_init(&actions)
            posix_spawnattr_init(&attrs)
            defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attrs) }
            posix_spawn_file_actions_adddup2(&actions, incoming[0], STDIN_FILENO)
            posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO)
            for fd in self.descriptors { posix_spawn_file_actions_addclose(&actions, fd) }
            var defaults = sigset_t()
            var mask = sigset_t()
            sigfillset(&defaults); sigemptyset(&mask)
            posix_spawnattr_setsigdefault(&attrs, &defaults)
            posix_spawnattr_setsigmask(&attrs, &mask)
            posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
            posix_spawnattr_setpgroup(&attrs, 0)
            let argv = ([path] + arguments).map { strdup($0) } + [nil]
            let env: [UnsafeMutablePointer<CChar>?] = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=en_US.UTF-8"].map { value in value.withCString { strdup($0) } } + [nil]
            defer { argv.compactMap { $0 }.forEach { free($0) }; env.compactMap { $0 }.forEach { free($0) } }
            let code = argv.withUnsafeBufferPointer { a in
                env.withUnsafeBufferPointer { e in
                    posix_spawn(&self.pid, path, &actions, &attrs, UnsafeMutablePointer(mutating: a.baseAddress!), UnsafeMutablePointer(mutating: e.baseAddress!))
                }
            }
            guard code == 0 else { self.finish(.failure(CommandError.processCreationFailed("spawn:\(code)"))); return }
            for fd in [out[1], err[1], incoming[0]] { self.closeDescriptor(fd) }
            for (index, fd) in [out[0], err[0]].enumerated() {
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
                reader.setEventHandler { self.drain(fd, index: index) }
                reader.setCancelHandler { close(fd) }
                self.readers[fd] = reader
                reader.resume()
            }
            self.input = input ?? Data()
            if self.input.isEmpty { self.closeDescriptor(incoming[1]) } else {
                let fd = incoming[1]
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                _ = fcntl(fd, F_SETNOSIGPIPE, 1)
                let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: self.queue)
                writer.setEventHandler { self.writeInput(fd) }
                writer.setCancelHandler { close(fd) }
                self.writer = writer
                self.writerDescriptor = fd
                writer.resume()
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { self.interrupt(.timeout) }
            self.timer = timer
            timer.resume()
            let child = self.pid
            DispatchQueue.global(qos: .userInitiated).async {
                var information = siginfo_t()
                var observed: Int32
                // 暂不回收已退出子进程，清理自身进程组前保留 PID，避免 PID 被复用。
                repeat { observed = waitid(P_PID, id_t(child), &information, WEXITED | WNOWAIT) } while observed < 0 && errno == EINTR
                let finalObserved = observed
                self.queue.async {
                    self.drain(out[0], index: 0)
                    self.drain(err[0], index: 1)
                    // 不允许本命令遗留持管道的后代；不影响任何其他进程组。
                    var finalStatus: Int32 = 0
                    var finalWaited: pid_t = -1
                    if finalObserved == 0 {
                        _ = kill(-child, SIGKILL)
                        repeat { finalWaited = waitpid(child, &finalStatus, 0) } while finalWaited < 0 && errno == EINTR
                    }
                    if let error = self.interruption { self.finish(.failure(error)) }
                    else if finalWaited < 0 { self.finish(.failure(CommandError.cancelled)) }
                    else {
                        let signalled = (finalStatus & 0x7f) != 0
                        self.finish(.success(CommandResult(exitCode: signalled ? finalStatus & 0x7f : (finalStatus >> 8) & 0xff,
                            stdout: String(decoding: self.output[0], as: UTF8.self), stderr: String(decoding: self.output[1], as: UTF8.self),
                            termination: signalled ? .signal : .exit)))
                    }
                }
            }
        }
    }

    func cancel() { queue.async { self.cancelled = true; if self.pid > 0 { self.interrupt(.cancelled) } } }

    private func interrupt(_ error: CommandError) {
        guard !finished, interruption == nil else { return }
        interruption = error
        _ = kill(-pid, SIGTERM)
        let child = pid
        queue.asyncAfter(deadline: .now() + 0.2) { if !self.finished { _ = kill(-child, SIGKILL) } }
    }

    private func drain(_ fd: Int32, index: Int) {
        guard !finished, descriptors.contains(fd) else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var budget = 256 * 1024
        while budget > 0 {
            let count = read(fd, &buffer, min(buffer.count, budget))
            if count > 0 {
                budget -= count
                let keep = min(count, max(0, outputLimit - output[index].count))
                output[index].append(contentsOf: buffer.prefix(keep))
            } else if count < 0 && errno == EINTR { continue }
            else {
                if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) {
                    retireReader(fd)
                }
                return
            }
        }
    }

    private func writeInput(_ fd: Int32) {
        guard !finished else { return }
        let count = input.withUnsafeBytes { bytes in
            write(fd, bytes.baseAddress!.advanced(by: inputOffset), input.count - inputOffset)
        }
        if count > 0 { inputOffset += count }
        if inputOffset == input.count || (count < 0 && errno != EAGAIN && errno != EINTR) {
            retireWriter(); input = Data()
        }
    }

    private func closeDescriptor(_ fd: Int32) { if let index = descriptors.firstIndex(of: fd) { close(fd); descriptors.remove(at: index) } }
    // Dispatch 必须完成源的注销后才能关闭 fd，否则系统复用 fd 时可能误伤另一条命令。
    private func retireReader(_ fd: Int32) {
        guard let reader = readers.removeValue(forKey: fd) else { return }
        descriptors.removeAll { $0 == fd }
        reader.setEventHandler {}; reader.cancel()
    }
    private func retireWriter() {
        guard let writer else { return }
        if let fd = writerDescriptor { descriptors.removeAll { $0 == fd } }
        writerDescriptor = nil; self.writer = nil
        writer.setEventHandler {}; writer.cancel()
    }
    private func finish(_ result: Result<CommandResult, Error>) {
        guard !finished else { return }
        finished = true
        timer?.setEventHandler {}; timer?.cancel(); timer = nil
        Array(readers.keys).forEach { retireReader($0) }
        retireWriter()
        descriptors.forEach { close($0) }; descriptors = []; input = Data()
        continuation?.resume(with: result); continuation = nil
    }
}

final class MockExecutor: CommandExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: CommandResult] = [:]
    private var calls: [(path: String, arguments: [String], hasStdin: Bool)] = []
    var invocations: [(path: String, arguments: [String], hasStdin: Bool)] { lock.withLock { calls } }
    func register(path: String, arguments: [String], result: CommandResult) { lock.withLock { responses[([path] + arguments).joined(separator: " ")] = result } }
    func registerPrefix(path: String, result: CommandResult) { lock.withLock { responses["PREFIX:\(path)"] = result } }
    func run(path: String, arguments: [String], stdinData: Data?, timeout: TimeInterval) async throws -> CommandResult {
        lock.withLock {
            calls.append((path, arguments, stdinData != nil))
            return responses[([path] + arguments).joined(separator: " ")] ?? responses["PREFIX:\(path)"] ?? CommandResult(exitCode: 0, stdout: "", stderr: "")
        }
    }
}
