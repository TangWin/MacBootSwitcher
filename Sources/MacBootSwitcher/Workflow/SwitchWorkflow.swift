import Foundation

@MainActor
final class SwitchWorkflow: ObservableObject {
    private let scanner: SystemScanning
    private let bootSetter: BootSetting
    private let restarter: RestartRequesting
    @Published var phase: Phase = .idle
    @Published var candidates: [SystemCandidate] = []
    @Published var selectedCandidate: SystemCandidate?
    @Published var selectedCandidateID: String? {
        didSet {
            selectedCandidate = candidates.first { $0.volumeGroupID == selectedCandidateID && $0.canSwitch }
        }
    }
    @Published var scanWarnings: [String] = []
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var resultTitle = ""
    @Published private(set) var resultKind: ResultKind?
    @Published private(set) var operationTarget: SystemCandidate?
    /// 只描述本次会话获得的反馈；刷新或取消新操作不能当作撤销。
    @Published private(set) var bootStateNotice: String?
    @Published var showConfirmation = false
    @Published var ownerUsername = ""
    @Published var ownerPassword = ""
    @Published var progress: [OperationProgress] = []
    @Published var events: [OperationEvent] = []
    @Published var scanStartedAt: TimeInterval?
    @Published var scanStatus = "正在读取系统卷组…"
    private var isOperating = false
    private var runningStep: String?
    var currentCandidate: SystemCandidate? { candidates.first { $0.isCurrent } }
    var targetCandidates: [SystemCandidate] { candidates.filter { !$0.isCurrent } }
    var blocksNormalClose: Bool { phase == .setting }
    var canRefresh: Bool { !isOperating && (phase == .idle || phase == .ready || phase == .failed || phase == .indeterminate || phase == .restartRequested) }

    init(scanner: SystemScanning = DiskutilScanner(), bootSetter: BootSetting = BlessBootSetter(), restarter: RestartRequesting = SystemRestarter()) {
        self.scanner = scanner; self.bootSetter = bootSetter; self.restarter = restarter
    }
    enum Phase: Equatable { case idle, scanning, ready, confirming, setting, restarting, restartRequested, indeterminate, failed }
    enum ResultKind: Equatable { case scanFailed, settingFailed, settingUnknown, restartRequested, restartFailed, restartUnknown }

    func scan() async {
        guard canRefresh else { return }
        isOperating = true
        defer { isOperating = false; scanStartedAt = nil }
        phase = .scanning; scanStartedAt = ProcessInfo.processInfo.systemUptime
        errorMessage = nil; statusMessage = nil; selectedCandidate = nil; selectedCandidateID = nil
        resultKind = nil; resultTitle = ""; scanWarnings = []
        do {
            let result = try await scanner.scan { [weak self] stage in await self?.updateScan(stage) }
            candidates = result.candidates; scanWarnings = result.warnings; phase = .ready
        } catch {
            errorMessage = "扫描失败：\(error.localizedDescription)"; candidates = []; phase = .failed
            resultKind = .scanFailed; resultTitle = "无法读取系统列表"
        }
    }
    private func updateScan(_ stage: ScanProgress) {
        switch stage {
        case .readingGroups: scanStatus = "正在读取系统卷组…"
        case .identifyingCurrentSystem: scanStatus = "正在确认当前运行系统…"
        case .checkingCandidates(let count, let total): scanStatus = "正在核对候选系统状态（\(count)/\(total)）…"
        }
    }
    func select(_ candidate: SystemCandidate) {
        guard phase == .ready, candidate.canSwitch, !isOperating else { return }
        selectedCandidateID = candidate.volumeGroupID
    }
    func requestConfirmation() {
        guard selectedCandidate != nil, phase == .ready, !isOperating else { return }
        if ownerUsername.isEmpty { ownerUsername = ProcessInfo.processInfo.userName }
        ownerPassword = ""
        phase = .confirming; showConfirmation = true
    }
    func cancelConfirmation() {
        guard phase == .confirming else { return }
        phase = .ready; showConfirmation = false; ownerPassword = ""
    }
    func executeSwitch(ownerUsername: String, ownerPassword: String) async {
        guard phase == .confirming, let target = selectedCandidate, !isOperating else { return }
        isOperating = true
        defer { isOperating = false; self.ownerPassword = "" }
        self.ownerPassword = ""
        phase = .setting; showConfirmation = false; errorMessage = nil; statusMessage = nil
        operationTarget = target; resultKind = nil; resultTitle = ""
        let targetDescription = "「\(target.name)」（标识 \(targetIdentifier(target))）"
        progress = [OperationProgress(id: "check", title: "检查所选目标"), OperationProgress(id: "authorize", title: "等待管理员授权"),
                    OperationProgress(id: "validate", title: "授权后重新核对目标"), OperationProgress(id: "set", title: "设置下一次启动"),
                    OperationProgress(id: "restart", title: "请求正常重启")]
        events = []; runningStep = nil
        startStep("check")
        guard target.identity.isValid, target.canSwitch else {
            finishStep(.failed); phase = .failed; errorMessage = "目标身份不完整，请重新扫描。"
            resultKind = .settingFailed; resultTitle = "启动设置未完成"; return
        }
        let result = await bootSetter.setNextBoot(target: target.identity, ownerUsername: ownerUsername, ownerPassword: ownerPassword) { [weak self] step in
            await self?.bootProgress(step)
        }
        switch result {
        case .cancelledBeforeExecution:
            finishStep(.cancelled); phase = .ready; statusMessage = "管理员认证已取消，未执行设置。"
        case .failure(let message):
            if progress.contains(where: { $0.id == "set" && $0.startedAt != nil }) {
                bootStateNotice = "对\(targetDescription)的设置工具报告失败，临时选择可能已改变。本应用无法查询或撤销；刷新只更新系统列表。"
            }
            finishStep(.failed); errorMessage = message + "\n未请求重启。"; phase = .failed
            resultKind = .settingFailed; resultTitle = "启动设置未完成"
        case .indeterminate(let message):
            bootStateNotice = "对\(targetDescription)的设置结果无法确认，临时选择可能仍有效。本应用无法查询或撤销；刷新只更新系统列表。"
            finishStep(.unknown); errorMessage = message + "\n临时选择可能仍有效；本应用无法独立确认或撤销。未自动重启或重试。"; phase = .indeterminate
            resultKind = .settingUnknown; resultTitle = "设置结果无法确认"
        case .success:
            bootStateNotice = "设置工具报告已将\(targetDescription)指定为下一次启动目标。若重启未完成，临时选择可能仍有效；取消重启、返回或刷新均不撤销该选择。"
            finishStep(.completed)
            // 写入阶段结束；正常重启必须能让本应用退出。
            phase = .restarting; startStep("restart")
            let restart = await restarter.requestRestart()
            switch restart {
            case .requested:
                finishStep(.completed); resultKind = .restartRequested; resultTitle = "重启请求已提交"
                statusMessage = "设置工具报告成功。请处理系统的文档保存提示，等待正常重启；若未完成重启，临时选择可能仍有效。"
            case .failed(let message):
                finishStep(.failed); resultKind = .restartFailed; resultTitle = "已设置临时选择，重启请求失败"
                statusMessage = "设置工具报告成功。" + message + "\n临时选择可能仍有效；请先保存工作，再自行安排正常重启。"
            case .indeterminate:
                finishStep(.unknown); resultKind = .restartUnknown; resultTitle = "重启结果无法确认"
                statusMessage = "设置工具报告成功，可能仍在等待系统或文档保存；临时选择可能有效，未重复发起重启。"
            }
            phase = .restartRequested
        }
    }
    private func bootProgress(_ step: BootProgress) {
        guard phase == .setting else { return }
        switch step {
        case .checkingTarget: startStep("check")
        case .awaitingAuthorization: startStep("authorize")
        case .recheckingTarget: startStep("validate")
        case .settingBoot: startStep("set")
        }
    }
    private func startStep(_ id: String) {
        if runningStep == id { return }
        if runningStep != nil { finishStep(.completed) }
        guard let index = progress.firstIndex(where: { $0.id == id }) else { return }
        progress[index].status = .running; progress[index].startedAt = ProcessInfo.processInfo.systemUptime; runningStep = id
        events.append(OperationEvent(message: progress[index].title + "…"))
    }
    private func finishStep(_ status: OperationProgress.Status) {
        guard let id = runningStep, let index = progress.firstIndex(where: { $0.id == id }) else { return }
        let elapsed = progress[index].startedAt.map { max(0, ProcessInfo.processInfo.systemUptime - $0) } ?? 0
        progress[index].elapsed = elapsed; progress[index].status = status
        let state: String
        switch status { case .completed: state = "完成"; case .failed: state = "失败"; case .unknown: state = "结果无法确认"; case .cancelled: state = "取消"; default: state = "等待" }
        events.append(OperationEvent(message: progress[index].title + "：" + state + "（\(Int(elapsed)) 秒）"))
        runningStep = nil
    }
    /// 短标识在本轮候选集合内唯一；碰撞时自动扩展。
    func targetIdentifier(_ target: SystemCandidate) -> String {
        let compact = target.volumeGroupID.replacingOccurrences(of: "-", with: "")
        for length in [8, 12, 16, 32] {
            let short = String(compact.prefix(length))
            if candidates.filter({ $0.volumeGroupID.replacingOccurrences(of: "-", with: "").hasPrefix(short) }).count <= 1 { return short }
        }
        return compact
    }
    func reset() {
        guard !isOperating else { return }
        phase = .idle; errorMessage = nil; statusMessage = nil; selectedCandidateID = nil
        resultKind = nil; resultTitle = ""
        showConfirmation = false; ownerPassword = ""
    }
}
