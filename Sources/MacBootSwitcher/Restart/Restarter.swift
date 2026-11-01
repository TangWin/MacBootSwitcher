import Foundation

enum RestartResult: Sendable, Equatable {
    case requested
    case failed(message: String)
    case indeterminate
}
protocol RestartRequesting: Sendable { func requestRestart() async -> RestartResult }

final class SystemRestarter: RestartRequesting {
    private let executor: CommandExecuting
    init(executor: CommandExecuting = ProcessExecutor()) { self.executor = executor }
    func requestRestart() async -> RestartResult {
        do {
            let result = try await executor.run(path: "/usr/bin/osascript", arguments: ["-e", "tell application \"System Events\" to restart"], timeout: 60)
            guard result.termination == .exit else { return .indeterminate }
            return result.exitCode == 0 ? .requested : .failed(message: "系统未接受本次正常重启请求（状态 \(result.exitCode)）。")
        } catch { return .indeterminate }
    }
}
final class MockRestarter: RestartRequesting, @unchecked Sendable {
    var resultToReturn: RestartResult = .requested
    private(set) var callCount = 0
    func requestRestart() async -> RestartResult { callCount += 1; return resultToReturn }
}
