import Foundation
import Darwin

/// 仅接受一次性设置；本次授权的副本运行结束即退出，不安装常驻 helper。
enum RestrictedBootRunner {
    static func run(socketPath: String) async -> Int32 {
        guard geteuid() == 0 else { return 1 }
        do {
            guard socketPath.hasPrefix("/private/tmp/MBS-"), (socketPath as NSString).lastPathComponent == "endpoint" else { return 1 }
            let directory = (socketPath as NSString).deletingLastPathComponent
            let identifier = ((directory as NSString).lastPathComponent).dropFirst(4)
            guard UUID(uuidString: String(identifier)) != nil else { return 1 }
            let connection = try BootSession.connect(socketPath)
            let caller = try connection.peerUID()
            var parent = stat()
            var endpoint = stat()
            guard caller != 0, lstat(directory, &parent) == 0, parent.st_uid == caller,
                  parent.st_mode & S_IFMT == S_IFDIR, parent.st_mode & 0o077 == 0,
                  lstat(socketPath, &endpoint) == 0, endpoint.st_uid == caller,
                  endpoint.st_mode & S_IFMT == S_IFSOCK else { return 1 }
            var request = try await blockingIO { try connection.receive(BootRequest.self, timeout: 10) }
            guard request.isValid else { try connection.send(BootMessage(outcome: "rejected")); return 0 }
            let operationLock: BootOperationLock
            do { operationLock = try BootOperationLock() }
            catch { try connection.send(BootMessage(outcome: "busy")); return 0 }
            // 执行侧持有锁直到其受控工具结束，界面失联不会解锁。
            defer { withExtendedLifetime(operationLock) {} }
            let result = await RestrictedBootOperation().execute(request: request) { message in try connection.send(message) }
            request.ownerPassword = ""
            try? connection.send(result)
            return 0
        } catch { return 1 }
    }
}

/// 纯适配边界允许使用模拟扫描器/执行器检验写前守卫，测试不运行真实启动写入。
struct RestrictedBootOperation: Sendable {
    var scanner: SystemScanning = DiskutilScanner()
    var executor: CommandExecuting = ProcessExecutor()
    func execute(request initial: BootRequest, onMessage: @escaping @Sendable (BootMessage) throws -> Void) async -> BootMessage {
        var request = initial
        guard request.isValid else { return BootMessage(outcome: "rejected") }
        do {
            try onMessage(BootMessage(step: .recheckingTarget))
            let mount = try await scanner.validateTarget(request.target)
            try onMessage(BootMessage(step: .settingBoot))
            let password = Data((request.ownerPassword + "\n").utf8)
            request.ownerPassword = ""
            let result = try await executor.run(path: "/usr/sbin/bless",
                arguments: ["--mount", mount, "--setBoot", "--nextonly", "--user", request.ownerUsername, "--stdinpass"],
                stdinData: password, timeout: 60)
            let outcome = result.termination == .signal ? "unknown" : result.exitCode == 0 ? "success" : "failure"
            return BootMessage(outcome: outcome, code: result.exitCode)
        } catch is ScanError { return BootMessage(outcome: "rejected") }
        catch { return BootMessage(outcome: "unknown") }
    }
}
