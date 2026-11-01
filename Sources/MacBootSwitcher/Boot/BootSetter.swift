import Foundation
import Security

/// 设置前取消与工具失败不混同于中断；字符串只能来自受限结果映射。
enum BlessResult: Sendable, Equatable {
    case cancelledBeforeExecution
    case success
    case failure(message: String)
    case indeterminate(message: String)
}

protocol BootSetting: Sendable {
    func setNextBoot(target: BootTarget, ownerUsername: String, ownerPassword: String,
                     onProgress: @escaping @Sendable (BootProgress) async -> Void) async -> BlessResult
}

final class BlessBootSetter: BootSetting {
    private let executor: CommandExecuting
    init(executor: CommandExecuting = ProcessExecutor()) { self.executor = executor }

    func setNextBoot(target: BootTarget, ownerUsername: String, ownerPassword: String,
                     onProgress: @escaping @Sendable (BootProgress) async -> Void) async -> BlessResult {
        let request = BootRequest(target: target, ownerUsername: ownerUsername, ownerPassword: ownerPassword)
        guard request.isValid else { return .failure(message: "目标身份或拥有者输入不完整，请重新确认。") }
        do {
            let session = try BootSession()
            let identity = try Self.runningCodeIdentity()
            guard Bundle.main.bundleURL.pathExtension == "app", let executable = Bundle.main.executableURL?.path else { return .failure(message: "无法确认应用执行入口。") }
            let script = Self.authorizationScript(executable: executable, cdhash: identity, socketPath: session.socketPath)
            await onProgress(.awaitingAuthorization)
            let monitor = Task.detached { () -> BlessResult in
                do {
                    let connection = try await blockingIO { try session.acceptRoot() }
                    try await blockingIO { try connection.send(request) }
                    var progressCount = 0
                    while true {
                        let message = try await blockingIO { try connection.receive(BootMessage.self, timeout: 150) }
                        if let step = message.step {
                            guard (progressCount == 0 && step == .recheckingTarget) || (progressCount == 1 && step == .settingBoot) else { return .indeterminate(message: "执行进展无法确认。") }
                            await onProgress(step)
                            progressCount += 1
                        }
                        if let outcome = message.outcome {
                            switch outcome {
                            case "success": return progressCount == 2 ? .success : .indeterminate(message: "未收到完整执行进展，不能确认结果。")
                            case "rejected": return .failure(message: "目标身份或就绪状态已变化，未执行启动设置，请重新扫描。")
                            case "busy": return .failure(message: "另一个切换操作正在执行，未执行本次设置。")
                            case "failure": return .failure(message: "系统工具报告失败（状态 \(message.code ?? -1)）；不能排除临时选择已改变。")
                            default: return .indeterminate(message: "系统执行中断或超时，临时选择可能仍然有效。")
                            }
                        }
                    }
                } catch { return .indeterminate(message: "与受限执行进程的连接已中断，无法确认设置结果。") }
            }
            do {
                let result = try await executor.run(path: "/usr/bin/osascript", arguments: ["-e", script], timeout: 300)
                session.stop()
                let reported = await monitor.value
                if result.termination == .exit, result.exitCode == 0 {
                    let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    if token == "AUTH_CANCELLED" { return .cancelledBeforeExecution }
                    if token == "AUTH_FAILED" { return .indeterminate(message: "管理员授权或受限入口未正常完成，未取得可信设置结果。") }
                    if token == "RUNNER_FINISHED" { return reported }
                }
                return .indeterminate(message: "授权执行链异常结束，无法确认设置结果。")
            } catch {
                session.abort()
                _ = await monitor.value
                return .indeterminate(message: "授权执行链超时或中断，未自动重启或重试。")
            }
        } catch { return .failure(message: "无法建立可信的按次授权入口，未执行设置。") }
    }

    static func runningCodeIdentity() throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { throw TransportError.invalid }
        var information: CFDictionary?
        // SDK 文档明确允许动态 SecCode；动态有效性检查保证磁盘代码与运行实例一致。
        let staticView = unsafeBitCast(code, to: SecStaticCode.self)
        guard SecCodeCopySigningInformation(staticView, [], &information) == errSecSuccess,
              let dict = information as? [String: Any], let hash = dict[kSecCodeInfoUnique as String] as? Data else { throw TransportError.invalid }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// shell 仅处理应用固定入口、代码身份和随机 IPC 地址，不含目标、账号或密码。
    static func authorizationScript(executable: String, cdhash: String, socketPath: String) -> String {
        let bundle = ((executable as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let appPath = (bundle as NSString).deletingLastPathComponent
        let command = "set -eu; stage=$(/usr/bin/mktemp -d /private/tmp/MBS-root.XXXXXXXX); trap '/bin/rm -rf \"$stage/runner.app\"; /bin/rmdir \"$stage\"' EXIT; /bin/cp -R " + escapeForShell(appPath) + " \"$stage/runner.app\"; for item in \"$stage/runner.app\" \"$stage/runner.app/Contents\" \"$stage/runner.app/Contents/MacOS\" \"$stage/runner.app/Contents/MacOS/MacBootSwitcher\"; do test ! -L \"$item\"; done; test -f \"$stage/runner.app/Contents/MacOS/MacBootSwitcher\"; /bin/chmod -R go-w \"$stage/runner.app\"; /usr/bin/codesign --verify --strict -R " + escapeForShell("=cdhash H\"\(cdhash)\"") + " \"$stage/runner.app\"; \"$stage/runner.app/Contents/MacOS/MacBootSwitcher\" --perform-next-boot " + escapeForShell(socketPath)
        return """
        try
            do shell script "\(escapeForAppleScriptString(command))" with administrator privileges
            return "RUNNER_FINISHED"
        on error errorText number errorNumber
            if errorNumber is -128 then
                return "AUTH_CANCELLED"
            end if
            return "AUTH_FAILED"
        end try
        """
    }
    static func escapeForShell(_ arg: String) -> String { "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func escapeForAppleScriptString(_ str: String) -> String { str.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
}

func blockingIO<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do { continuation.resume(returning: try operation()) }
            catch { continuation.resume(throwing: error) }
        }
    }
}

final class MockBootSetter: BootSetting, @unchecked Sendable {
    var resultToReturn: BlessResult = .success
    private(set) var lastTarget: BootTarget?
    private(set) var lastUsername: String?
    private(set) var callCount = 0
    func setNextBoot(target: BootTarget, ownerUsername: String, ownerPassword: String,
                     onProgress: @escaping @Sendable (BootProgress) async -> Void) async -> BlessResult {
        callCount += 1; lastTarget = target; lastUsername = ownerUsername
        await onProgress(.awaitingAuthorization)
        if resultToReturn != .cancelledBeforeExecution { await onProgress(.recheckingTarget) }
        if resultToReturn == .success { await onProgress(.settingBoot) }
        return resultToReturn
    }
}
