import Testing
import Foundation
import Darwin
@testable import MacBootSwitcher

private let rootID = "11111111-1111-1111-1111-111111111111"
private let targetID = "33333333-3333-3333-3333-333333333333"
private let targetUUID = "44444444-4444-4444-4444-444444444444"
private let target = BootTarget(volumeGroupID: targetID, systemVolumeUUID: targetUUID)

private func plist(_ value: Any) throws -> CommandResult {
    CommandResult(exitCode: 0, stdout: String(decoding: try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0), as: UTF8.self), stderr: "")
}
private struct Fixture {
    var groups: [String: Any]
    var infos: [String: [String: Any]]
    init() throws {
        let resource = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        groups = try PropertyListSerialization.propertyList(from: Data(contentsOf: resource.appendingPathComponent("two_systems.plist")), format: nil) as! [String: Any]
        infos = try PropertyListSerialization.propertyList(from: Data(contentsOf: resource.appendingPathComponent("volume_info.plist")), format: nil) as! [String: [String: Any]]
    }
    func executor() throws -> MockExecutor {
        let e = MockExecutor()
        e.register(path: "/usr/sbin/diskutil", arguments: ["apfs", "listVolumeGroups", "-plist"], result: try plist(groups))
        for (device, info) in infos { e.register(path: "/usr/sbin/diskutil", arguments: ["info", "-plist", device], result: try plist(info)) }
        return e
    }
}

@Suite("真实卷组解析与身份守卫")
struct DiscoveryTests {
    @Test("读取实际解析器与脱敏fixture，识别根快照及同名目标")
    func parsesFixture() async throws {
        let e = try Fixture().executor()
        let result = try await DiskutilScanner(executor: e).scan()
        #expect(result.candidates.count == 2)
        #expect(result.currentSystemID == rootID)
        #expect(result.candidates.first { $0.isCurrent }?.canSwitch == false)
        #expect(result.candidates.first { $0.volumeGroupID == targetID }?.canSwitch == true)
        #expect(e.invocations.count == 6)
        #expect(Set(e.invocations.map { $0.arguments.joined(separator: " ") }).count == 6)
    }
    @Test("根身份缺失不开放切换")
    func missingRoot() async throws {
        var f = try Fixture(); f.infos["/"] = [:]
        await #expect(throws: ScanError.self) { _ = try await DiskutilScanner(executor: f.executor()).scan() }
        await #expect(throws: ScanError.self) { _ = try await DiskutilScanner(executor: f.executor()).validateTarget(target) }
        f.infos["/"] = ["APFSVolumeGroupID": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"]
        await #expect(throws: ScanError.self) { _ = try await DiskutilScanner(executor: f.executor()).validateTarget(target) }
    }
    @Test("未知锁定字段不会假定安全，内外置保持未知")
    func missingFields() async throws {
        var f = try Fixture(); f.infos["disk99s3"]?.removeValue(forKey: "Locked"); f.infos["disk99s3"]?.removeValue(forKey: "Internal")
        let result = try await DiskutilScanner(executor: f.executor()).scan()
        let candidate = result.candidates.first { $0.volumeGroupID == targetID }
        #expect(candidate?.canSwitch == false); #expect(candidate?.isInternal == nil)
    }
    @Test("System或Data锁定、未挂载均禁用")
    func unavailable() async throws {
        for device in ["disk99s3", "disk99s4"] {
            var f = try Fixture(); f.infos[device]?["Locked"] = true
            let result = try await DiskutilScanner(executor: f.executor()).scan()
            #expect(result.candidates.first { $0.volumeGroupID == targetID }?.readiness == .locked)
        }
        var f = try Fixture(); f.infos["disk99s3"]?.removeValue(forKey: "MountPoint")
        let result = try await DiskutilScanner(executor: f.executor()).scan()
        #expect(result.candidates.first { $0.volumeGroupID == targetID }?.readiness == .notMounted)
    }
    @Test("孤立System不标为就绪，重复卷组直接拒绝")
    func orphanAndDuplicates() async throws {
        var f = try Fixture()
        var containers = f.groups["Containers"] as! [[String: Any]]
        var groups = containers[0]["VolumeGroups"] as! [[String: Any]]
        var volumes = groups[1]["Volumes"] as! [[String: Any]]; volumes.removeLast(); groups[1]["Volumes"] = volumes
        containers[0]["VolumeGroups"] = groups; f.groups["Containers"] = containers
        let result = try await DiskutilScanner(executor: f.executor()).scan()
        #expect(result.candidates.first { $0.volumeGroupID == targetID }?.canSwitch == false)
        groups.append(groups[1]); containers[0]["VolumeGroups"] = groups; f.groups["Containers"] = containers
        await #expect(throws: ScanError.self) { _ = try await DiskutilScanner(executor: f.executor()).scan() }
    }
    @Test("写前只检查选定目标，5次命令且不用全量扫描")
    func focusedValidation() async throws {
        let e = try Fixture().executor()
        let mount = try await DiskutilScanner(executor: e).validateTarget(target)
        #expect(mount == "/Volumes/SyntheticTarget")
        #expect(e.invocations.count == 5)
        #expect(!e.invocations.contains { $0.arguments.contains("disk99s1") || $0.arguments.contains("disk99s2") })
    }
    @Test("System身份变化、断开与挂载对象不符均拒绝")
    func identityChanges() async throws {
        for key in ["disk99s3", "/Volumes/SyntheticTarget"] {
            var f = try Fixture(); f.infos[key]?["VolumeUUID"] = "88888888-8888-8888-8888-888888888888"
            await #expect(throws: ScanError.self) { _ = try await DiskutilScanner(executor: f.executor()).validateTarget(target) }
        }
        var f = try Fixture(); f.infos["disk99s3"] = [:]
        await #expect(throws: ScanError.self) { _ = try await DiskutilScanner(executor: f.executor()).validateTarget(target) }
    }
    @Test("身份未变仅换路径时使用重新核验的新路径")
    func freshMount() async throws {
        var f = try Fixture(); f.infos["disk99s3"]?["MountPoint"] = "/Volumes/NewSyntheticTarget"
        f.infos["/Volumes/NewSyntheticTarget"] = f.infos["disk99s3"]
        let mount = try await DiskutilScanner(executor: f.executor()).validateTarget(target)
        #expect(mount == "/Volumes/NewSyntheticTarget")
    }
    @Test("不能验证当前系统为目标")
    func rejectCurrent() async throws {
        let current = BootTarget(volumeGroupID: rootID, systemVolumeUUID: "22222222-2222-2222-2222-222222222222")
        await #expect(throws: ScanError.self) { _ = try await DiskutilScanner(executor: Fixture().executor()).validateTarget(current) }
    }
}

@Suite("真实执行器的有限等待")
struct ExecutorTests {
    @Test("双路大输出同时排空且成功完整返回")
    func largeOutput() async throws {
        let r = try await ProcessExecutor().run(path: "/bin/sh", arguments: ["-c", "/usr/bin/head -c 262144 /dev/zero; /usr/bin/head -c 262144 /dev/zero >&2"], timeout: 3)
        #expect(r.exitCode == 0); #expect(r.stdout.utf8.count == 262144); #expect(r.stderr.utf8.count == 262144)
    }
    @Test("忽略TERM仍在有限时间结束")
    func boundedTimeout() async throws {
        let start = Date()
        await #expect(throws: CommandError.self) { _ = try await ProcessExecutor().run(path: "/bin/sh", arguments: ["-c", "trap '' TERM; /bin/sleep 5"], timeout: 0.2) }
        #expect(Date().timeIntervalSince(start) < 2)
    }
    @Test("父进程结束不等待持管道后代")
    func descendants() async throws {
        let start = Date()
        let r = try await ProcessExecutor().run(path: "/bin/sh", arguments: ["-c", "(/bin/sleep 5) & exit 0"], timeout: 2)
        #expect(r.exitCode == 0); #expect(Date().timeIntervalSince(start) < 2)
    }
    @Test("取消睡眠任务不会等待原始睡眠结束")
    func cancellation() async throws {
        let start = Date()
        let task = Task { try await ProcessExecutor().run(path: "/bin/sleep", arguments: ["5"], timeout: 10) }
        try await Task.sleep(nanoseconds: 100_000_000); task.cancel()
        do { _ = try await task.value; Issue.record("取消应返回错误") } catch {}
        #expect(Date().timeIntervalSince(start) < 2)
    }
    @Test("信号退出与工具退出分开")
    func signalExit() async throws {
        let r = try await ProcessExecutor().run(path: "/bin/sh", arguments: ["-c", "kill -TERM $$"], timeout: 2)
        #expect(r.termination == .signal)
    }
    @Test("进程无法创建立即失败")
    func missingExecutable() async {
        await #expect(throws: CommandError.self) { _ = try await ProcessExecutor().run(path: "/no/such/executable", arguments: [], timeout: 1) }
    }
    @Test("大输入不在启动前阻塞，输入与输出完整")
    func largeInput() async throws {
        let data = Data(repeating: 65, count: 262144)
        let r = try await ProcessExecutor().run(path: "/bin/cat", arguments: [], stdinData: data, timeout: 3)
        #expect(r.stdout.utf8.count == data.count)
    }
    @Test("并行短进程频繁复用描述符仍完整返回")
    func descriptorReuse() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    let expected = "synthetic-\(index)"
                    let result = try await ProcessExecutor().run(path: "/usr/bin/printf", arguments: ["%s", expected], timeout: 5)
                    #expect(result.termination == .exit); #expect(result.exitCode == 0); #expect(result.stdout == expected)
                }
            }
            try await group.waitForAll()
        }
    }
}

private final class MockScanner: SystemScanning, @unchecked Sendable {
    var count = 0
    var error: ScanError?
    func scan(onProgress: @escaping @Sendable (ScanProgress) async -> Void) async throws -> ScanResult {
        count += 1
        if let error { throw error }
        return ScanResult(candidates: [SystemCandidate(volumeGroupID: rootID, systemVolumeUUID: "22222222-2222-2222-2222-222222222222", name: "macOS", version: nil, isInternal: true, isCurrent: true, readiness: .currentSystem),
            SystemCandidate(volumeGroupID: targetID, systemVolumeUUID: targetUUID, name: "macOS", version: nil, isInternal: true, isCurrent: false, readiness: .ready)], currentSystemID: rootID, warnings: [])
    }
    func validateTarget(_ target: BootTarget) async throws -> String { Issue.record("Workflow不应重复全机验证"); return "" }
}
private actor GateSetter: BootSetting {
    var calls = 0
    var gate: CheckedContinuation<BlessResult, Never>?
    func setNextBoot(target: BootTarget, ownerUsername: String, ownerPassword: String, onProgress: @escaping @Sendable (BootProgress) async -> Void) async -> BlessResult {
        calls += 1; await onProgress(.awaitingAuthorization)
        return await withCheckedContinuation { gate = $0 }
    }
    func release() { gate?.resume(returning: .indeterminate(message: "合成中断")); gate = nil }
    func isWaiting() -> Bool { gate != nil }
}

private struct WritingFailureSetter: BootSetting {
    func setNextBoot(target: BootTarget, ownerUsername: String, ownerPassword: String,
                     onProgress: @escaping @Sendable (BootProgress) async -> Void) async -> BlessResult {
        await onProgress(.awaitingAuthorization)
        await onProgress(.recheckingTarget)
        await onProgress(.settingBoot)
        return .failure(message: "合成工具失败；不能排除临时选择已改变。")
    }
}

@Suite("流程互斥、真实进展与结果")
struct WorkflowTests {
    @MainActor private func prepared(_ setter: BootSetting, restart: MockRestarter = MockRestarter()) async -> (SwitchWorkflow, MockScanner) {
        let scanner = MockScanner(); let w = SwitchWorkflow(scanner: scanner, bootSetter: setter, restarter: restart)
        await w.scan(); w.select(w.targetCandidates[0]); w.requestConfirmation()
        return (w, scanner)
    }
    @Test("只有明确成功才请求重启，进展按真实事件完成") @MainActor
    func success() async {
        let setter = MockBootSetter(); let restart = MockRestarter(); let (w, scanner) = await prepared(setter, restart: restart)
        await w.executeSwitch(ownerUsername: "synthetic", ownerPassword: "synthetic-secret")
        #expect(restart.callCount == 1); #expect(w.phase == .restartRequested); #expect(w.progress.allSatisfy { $0.status == .completed })
        #expect(w.resultKind == .restartRequested); #expect(w.bootStateNotice != nil)
        #expect(scanner.count == 1); #expect(setter.lastTarget == target)
        #expect(!w.events.contains { $0.message.contains("synthetic-secret") || $0.message.contains(targetID) })
    }
    @Test("取消、失败和未知不重启或自动重试") @MainActor
    func stoppedResults() async {
        for result in [BlessResult.cancelledBeforeExecution, .failure(message: "工具失败"), .indeterminate(message: "工具中断")] {
            let setter = MockBootSetter(); setter.resultToReturn = result
            let restart = MockRestarter(); let (w, _) = await prepared(setter, restart: restart)
            await w.executeSwitch(ownerUsername: "synthetic", ownerPassword: "secret")
            #expect(restart.callCount == 0); #expect(setter.callCount == 1); #expect(w.progress.last?.status == .waiting)
        }
    }
    @Test("正常重启失败和未知的标题不伪报已提交") @MainActor
    func restartFailure() async {
        for (result, kind) in [(RestartResult.failed(message: "合成失败"), SwitchWorkflow.ResultKind.restartFailed), (.indeterminate, .restartUnknown)] {
            let restart = MockRestarter(); restart.resultToReturn = result
            let (w, _) = await prepared(MockBootSetter(), restart: restart)
            await w.executeSwitch(ownerUsername: "synthetic", ownerPassword: "secret")
            #expect(w.resultTitle != "重启请求已提交"); #expect(w.statusMessage?.contains("临时选择") == true)
            #expect(w.resultKind == kind); #expect(w.bootStateNotice != nil)
            #expect(!w.blocksNormalClose)
            let notice = w.bootStateNotice
            await w.scan()
            #expect(w.phase == .ready); #expect(w.bootStateNotice == notice)
        }
    }
    @Test("挂起操作时重复提交、刷新、改选无效，关闭保护有效") @MainActor
    func guards() async {
        let setter = GateSetter(); let (w, scanner) = await prepared(setter)
        let operation = Task { await w.executeSwitch(ownerUsername: "synthetic", ownerPassword: "secret") }
        while !(await setter.isWaiting()) { await Task.yield() }
        #expect(w.blocksNormalClose); #expect(w.progress.first { $0.id == "authorize" }?.status == .running)
        #expect(w.progress.first { $0.id == "set" }?.status == .waiting)
        await w.executeSwitch(ownerUsername: "synthetic", ownerPassword: "secret"); await w.scan(); w.reset()
        #expect(scanner.count == 1); #expect(await setter.calls == 1); #expect(w.phase == .setting)
        await setter.release(); await operation.value; #expect(!w.blocksNormalClose)
    }
    @Test("同名目标可辨识，短标识碰撞自动扩展") @MainActor
    func distinctNames() async {
        let (w, _) = await prepared(MockBootSetter())
        let first = w.targetCandidates[0]
        let second = SystemCandidate(volumeGroupID: "33333333-3333-3333-3333-333333333334", systemVolumeUUID: targetUUID, name: first.name, version: first.version, isInternal: true, isCurrent: false, readiness: .ready)
        w.candidates.append(second)
        #expect(w.targetIdentifier(first) != w.targetIdentifier(second))
    }
    @Test("扫描失败单独分类且不调用设置或重启") @MainActor
    func scanFailurePresentation() async {
        let scanner = MockScanner(); scanner.error = .noContainersFound
        let setter = MockBootSetter(); let restart = MockRestarter()
        let w = SwitchWorkflow(scanner: scanner, bootSetter: setter, restarter: restart)
        await w.scan()
        #expect(w.resultKind == .scanFailed); #expect(w.resultTitle == "无法读取系统列表")
        #expect(w.bootStateNotice == nil); #expect(!w.showConfirmation)
        #expect(setter.callCount == 0); #expect(restart.callCount == 0)
    }
    @Test("合并弹窗取消后清空密码、保留选择并可再次确认") @MainActor
    func confirmationDismissal() async {
        let setter = MockBootSetter(); let (w, _) = await prepared(setter)
        let selection = w.selectedCandidateID
        #expect(w.phase == .confirming); #expect(w.showConfirmation)
        w.ownerPassword = "synthetic-secret"
        w.cancelConfirmation()
        #expect(w.phase == .ready); #expect(!w.showConfirmation); #expect(w.ownerPassword.isEmpty)
        #expect(w.selectedCandidateID == selection); #expect(setter.callCount == 0)
        w.requestConfirmation()
        #expect(w.showConfirmation); #expect(w.ownerPassword.isEmpty)
    }
    @Test("未知设置提醒在返回、扫描失败、刷新与取消后均保留") @MainActor
    func unknownNoticeSurvivesNavigation() async {
        let setter = MockBootSetter(); setter.resultToReturn = .indeterminate(message: "合成中断")
        let restart = MockRestarter(); let (w, scanner) = await prepared(setter, restart: restart)
        await w.executeSwitch(ownerUsername: "synthetic", ownerPassword: "secret")
        #expect(w.resultKind == .settingUnknown)
        let notice = w.bootStateNotice
        #expect(notice?.contains("无法确认") == true)
        #expect(notice?.contains(w.targetIdentifier(w.operationTarget!)) == true)
        w.reset(); scanner.error = .noContainersFound; await w.scan()
        #expect(w.resultKind == .scanFailed); #expect(w.bootStateNotice == notice)
        scanner.error = nil; await w.scan()
        #expect(w.phase == .ready); #expect(w.selectedCandidate == nil); #expect(w.bootStateNotice == notice)
        w.select(w.targetCandidates[0]); w.requestConfirmation(); w.cancelConfirmation()
        #expect(w.bootStateNotice == notice)
        setter.resultToReturn = .cancelledBeforeExecution
        w.requestConfirmation(); await w.executeSwitch(ownerUsername: "synthetic", ownerPassword: "secret")
        #expect(w.phase == .ready); #expect(w.bootStateNotice == notice)
        setter.resultToReturn = .failure(message: "合成写入前拒绝")
        w.requestConfirmation(); await w.executeSwitch(ownerUsername: "synthetic", ownerPassword: "secret")
        #expect(w.bootStateNotice == notice); #expect(restart.callCount == 0)
    }
    @Test("写入阶段失败留下提醒，写入前拒绝不编造新的临时状态") @MainActor
    func writingFailureNotice() async {
        let restart = MockRestarter(); let (w, _) = await prepared(WritingFailureSetter(), restart: restart)
        await w.executeSwitch(ownerUsername: "synthetic", ownerPassword: "secret")
        #expect(w.resultKind == .settingFailed); #expect(w.bootStateNotice?.contains("可能已改变") == true)
        let notice = w.bootStateNotice
        await w.scan(); #expect(w.bootStateNotice == notice); #expect(restart.callCount == 0)
        let early = MockBootSetter(); early.resultToReturn = .failure(message: "合成写入前拒绝")
        let (beforeWrite, _) = await prepared(early)
        await beforeWrite.executeSwitch(ownerUsername: "synthetic", ownerPassword: "secret")
        #expect(beforeWrite.resultKind == .settingFailed); #expect(beforeWrite.bootStateNotice == nil)
    }
}

@Suite("受限入口与诊断")
struct BootBoundaryTests {
    @Test("授权脚本没有目标路径、owner用户名、密码或bless")
    func restrictedScript() {
        let script = BlessBootSetter.authorizationScript(executable: "/Applications/MacBootSwitcher.app/Contents/MacOS/MacBootSwitcher", cdhash: String(repeating: "a", count: 40), socketPath: "/private/tmp/MBS-SYNTHETIC/endpoint")
        #expect(script.contains("=cdhash")); #expect(script.contains("--perform-next-boot"))
        #expect(!script.contains("/usr/sbin/bless")); #expect(!script.contains("--mount")); #expect(!script.contains("--user"))
        #expect(script.contains("AUTH_CANCELLED")); #expect(!script.contains("canceled"))
    }
    @Test("无效身份及过长凭据被拒绝")
    func invalidRequest() {
        #expect(!BootRequest(target: BootTarget(volumeGroupID: "bad", systemVolumeUUID: "bad"), ownerUsername: "x", ownerPassword: "x").isValid)
        #expect(!BootRequest(target: target, ownerUsername: "x", ownerPassword: String(repeating: "x", count: 4097)).isValid)
    }
    @Test("跨实例锁不能被第二执行者取得，释放后可取得")
    func lockContention() throws {
        let path = "/private/tmp/MBS-lock-test-\(UUID().uuidString)"
        defer { unlink(path) }
        var first: BootOperationLock? = try BootOperationLock(path: path, owner: geteuid())
        #expect(first != nil)
        #expect(throws: TransportError.self) { _ = try BootOperationLock(path: path, owner: geteuid()) }
        first = nil
        let second = try BootOperationLock(path: path, owner: geteuid())
        withExtendedLifetime(second) {}
    }
    @Test("锁文件符号链接被拒绝")
    func symlinkLock() throws {
        let path = "/private/tmp/MBS-link-test-\(UUID().uuidString)"; defer { unlink(path) }
        #expect(symlink("/dev/null", path) == 0)
        #expect(throws: TransportError.self) { _ = try BootOperationLock(path: path, owner: geteuid()) }
    }
    @Test("非root内部入口直接拒绝，不读取磁盘或写入")
    func rejectNonRoot() async {
        #expect(geteuid() != 0)
        #expect(await RestrictedBootRunner.run(socketPath: "/private/tmp/unused") == 1)
    }
    @Test("重启适配不会显示系统原始账号、路径或错误文本")
    func sanitizedRestart() async {
        let e = MockExecutor(); e.registerPrefix(path: "/usr/bin/osascript", result: CommandResult(exitCode: 1, stdout: "", stderr: "private-user /Volumes/private sentinel-password"))
        let result = await SystemRestarter(executor: e).requestRestart()
        if case .failed(let message) = result { #expect(!message.contains("private")); #expect(!message.contains("sentinel")) }
        else { Issue.record("预期明确失败") }
    }
}

@Suite("执行侧写前核验与有限进程边界")
struct RunnerOperationTests {
    @Test("真实核验拒绝后不调用bless，授权等待后的信息变化有效")
    func noWriteAfterChangedIdentity() async throws {
        var f = try Fixture(); f.infos["/Volumes/SyntheticTarget"]?["VolumeUUID"] = "88888888-8888-8888-8888-888888888888"
        let executor = MockExecutor()
        let operation = RestrictedBootOperation(scanner: DiskutilScanner(executor: try f.executor()), executor: executor)
        let result = await operation.execute(request: BootRequest(target: target, ownerUsername: "synthetic", ownerPassword: "sentinel-password"), onMessage: { _ in })
        #expect(result.outcome == "rejected"); #expect(executor.invocations.isEmpty)
    }
    @Test("仅真实核验通过后使用即时路径与固定参数，密码不进入参数")
    func fixedCommand() async throws {
        let executor = MockExecutor()
        let operation = RestrictedBootOperation(scanner: DiskutilScanner(executor: try Fixture().executor()), executor: executor)
        let result = await operation.execute(request: BootRequest(target: target, ownerUsername: "synthetic", ownerPassword: "sentinel-password"), onMessage: { _ in })
        #expect(result.outcome == "success"); #expect(executor.invocations.count == 1)
        let call = executor.invocations[0]
        #expect(call.path == "/usr/sbin/bless")
        #expect(call.arguments == ["--mount", "/Volumes/SyntheticTarget", "--setBoot", "--nextonly", "--user", "synthetic", "--stdinpass"])
        #expect(call.hasStdin); #expect(!call.arguments.contains("sentinel-password"))
    }
    @Test("执行前进展连接中断时不写入")
    func disconnectedBeforeWrite() async throws {
        let executor = MockExecutor()
        let operation = RestrictedBootOperation(scanner: DiskutilScanner(executor: try Fixture().executor()), executor: executor)
        let result = await operation.execute(request: BootRequest(target: target, ownerUsername: "synthetic", ownerPassword: "secret")) { message in
            if message.step == .settingBoot { throw TransportError.disconnected }
        }
        #expect(result.outcome == "unknown"); #expect(executor.invocations.isEmpty)
    }
    @Test("错误中的取消词不等于设置前取消，信号退出归未知")
    func errorClassification() async throws {
        for termination in [CommandResult.Termination.exit, .signal] {
            let executor = MockExecutor()
            executor.registerPrefix(path: "/usr/sbin/bless", result: CommandResult(exitCode: 1, stdout: "", stderr: "canceled (-128) sentinel-password private-user", termination: termination))
            let operation = RestrictedBootOperation(scanner: DiskutilScanner(executor: try Fixture().executor()), executor: executor)
            let result = await operation.execute(request: BootRequest(target: target, ownerUsername: "synthetic", ownerPassword: "secret"), onMessage: { _ in })
            #expect(result.outcome == (termination == .signal ? "unknown" : "failure"))
            #expect(!String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("sentinel"))
        }
    }
    @Test("持续输出与提前关闭输出时超时仍有效")
    func outputFairness() async {
        for command in ["while :; do /usr/bin/printf xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; done", "exec 1>&- 2>&-; /bin/sleep 5"] {
            let start = Date()
            await #expect(throws: CommandError.self) { _ = try await ProcessExecutor().run(path: "/bin/sh", arguments: ["-c", command], timeout: 0.2) }
            #expect(Date().timeIntervalSince(start) < 2)
        }
    }
    @Test("Data身份大小写无关，成员被替换时拒绝")
    func dataIdentity() async throws {
        var f = try Fixture()
        var containers = f.groups["Containers"] as! [[String: Any]]
        var groups = containers[0]["VolumeGroups"] as! [[String: Any]]
        var members = groups[1]["Volumes"] as! [[String: Any]]
        let dataUUID = "ABCDEFAB-ABCD-ABCD-ABCD-ABCDEFABCDEF"
        members[1]["DiskUUID"] = dataUUID
        groups[1]["Volumes"] = members; containers[0]["VolumeGroups"] = groups; f.groups["Containers"] = containers
        f.infos["disk99s4"]?["VolumeUUID"] = dataUUID.lowercased()
        let valid = try await DiskutilScanner(executor: f.executor()).validateTarget(target)
        #expect(valid == "/Volumes/SyntheticTarget")
        f.infos["disk99s4"]?["VolumeUUID"] = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        await #expect(throws: ScanError.self) { _ = try await DiskutilScanner(executor: f.executor()).validateTarget(target) }
        let result = try await DiskutilScanner(executor: f.executor()).scan()
        #expect(result.candidates.first { $0.volumeGroupID == targetID }?.canSwitch == false)
    }
}
