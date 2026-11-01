import SwiftUI
import Foundation
import AppKit

/// 单次启动切换窗口：目标选择、按次认证和真实阶段反馈。
struct ContentView: View {
    @ObservedObject var workflow: SwitchWorkflow
    @FocusState private var candidateListFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if let notice = workflow.bootStateNotice {
                noticeView(notice)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
            }
            mainContentArea
            Divider()
            footerBar
        }
        .frame(minWidth: 520, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await workflow.scan() }
        .sheet(isPresented: confirmationBinding) {
            ConfirmationView(workflow: workflow)
        }
    }

    // 弹窗的系统关闭行为也必须回到可选择状态并清空密码引用。
    private var confirmationBinding: Binding<Bool> {
        Binding(get: { workflow.showConfirmation }, set: { presented in
            if !presented { workflow.cancelConfirmation() }
        })
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.swap")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("MacBootSwitcher").font(.headline)
                Text("仅影响下一次启动，默认启动盘保持不变")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await workflow.scan() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(!workflow.canRefresh)
            .keyboardShortcut("r", modifiers: .command)
            .help("重新扫描系统列表，不改变或撤销启动选择")
        }
        .padding(20)
    }

    @ViewBuilder
    private var mainContentArea: some View {
        switch workflow.phase {
        case .idle, .scanning:
            loadingView
        case .ready, .confirming:
            candidatesContainer
        case .setting, .restarting:
            operationProgressView
        case .restartRequested, .indeterminate, .failed:
            resultStateView
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(workflow.scanStatus).foregroundStyle(.secondary)
            if let started = workflow.scanStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("已等待 \(max(0, Int(ProcessInfo.processInfo.systemUptime - started))) 秒")
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var candidatesContainer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("下一次启动到哪个系统？").font(.title3.weight(.semibold))
                if let current = workflow.currentCandidate {
                    Label("当前运行：\(current.name) · \(current.storageDescription)", systemImage: "desktopcomputer")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let message = workflow.statusMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                if !workflow.scanWarnings.isEmpty {
                    DisclosureGroup("扫描提示（\(workflow.scanWarnings.count)）") {
                        ForEach(Array(workflow.scanWarnings.enumerated()), id: \.offset) { _, warning in
                            Text(warning).font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if workflow.targetCandidates.isEmpty {
                    emptyTargetsView
                } else {
                    VStack(spacing: 10) {
                        ForEach(workflow.targetCandidates) { candidate in
                            candidateCard(candidate: candidate)
                        }
                    }
                    .focusable()
                    .focused($candidateListFocused)
                    .onMoveCommand(perform: moveSelection)
                    .onAppear { candidateListFocused = true }
                    .onChange(of: workflow.phase) { _, phase in
                        if phase == .ready { candidateListFocused = true }
                    }
                }
                if workflow.targetCandidates.contains(where: { $0.readiness == .locked || $0.readiness == .notMounted }) {
                    openDiskUtilityButton
                }
                Text("发现系统候选不代表已确认可启动。")
                    .font(.callout).foregroundStyle(.secondary)
                if !workflow.events.isEmpty { eventLog }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func candidateCard(candidate: SystemCandidate) -> some View {
        let isSelected = workflow.selectedCandidateID == candidate.volumeGroupID
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                workflow.select(candidate)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                    Image(systemName: candidateIcon(candidate))
                        .font(.title2).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(candidate.name).font(.headline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(candidate.version ?? "版本未知") · \(candidate.storageDescription)")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("标识：\(workflow.targetIdentifier(candidate))")
                            .font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(isSelected ? "已选中" : candidate.canSwitch ? "可选择" : "不可选择")
                        .font(.callout)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!candidate.canSwitch || workflow.phase != .ready)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(candidate.name)，\(candidate.version ?? "版本未知")，\(candidate.storageDescription)，标识 \(workflow.targetIdentifier(candidate))")
            .accessibilityValue(isSelected ? "已选中" : candidate.readinessDescription)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            if !candidate.canSwitch {
                Text(candidate.readinessDescription)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1))
    }

    private func candidateIcon(_ candidate: SystemCandidate) -> String {
        switch candidate.isInternal {
        case true?: return "internaldrive"
        case false?: return "externaldrive"
        case nil: return "questionmark.folder"
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard workflow.phase == .ready, direction == .up || direction == .down else { return }
        let targets = workflow.targetCandidates.filter(\.canSwitch)
        guard !targets.isEmpty else { return }
        let index = targets.firstIndex { $0.volumeGroupID == workflow.selectedCandidateID }
        let next = index.map { min(max($0 + (direction == .down ? 1 : -1), 0), targets.count - 1) }
            ?? (direction == .down ? 0 : targets.count - 1)
        workflow.select(targets[next])
    }

    private var emptyTargetsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("未发现其他 macOS 系统").font(.headline)
            Text("如已接入其他系统磁盘，请在「磁盘工具」中检查其状态，然后刷新。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            openDiskUtilityButton
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    private var openDiskUtilityButton: some View {
        Button("打开磁盘工具") {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.DiskUtility") else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
        .help("仅打开系统应用；挂载或解锁须由你自行操作")
    }

    private func noticeView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityHidden(true)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var operationProgressView: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 16) {
                    Text("切换进展").font(.title3.weight(.semibold))
                    if let target = workflow.operationTarget { operationTargetView(target) }
                    ForEach(workflow.progress) { step in
                        HStack(spacing: 10) {
                            if step.status == .running {
                                ProgressView().controlSize(.small).frame(width: 16)
                            } else {
                                Image(systemName: stepIcon(step.status)).frame(width: 16)
                                    .foregroundStyle(stepColor(step.status)).accessibilityHidden(true)
                            }
                            Text(step.title)
                            Spacer()
                            Text(stepStatus(step)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Text(operationInstruction).font(.callout).foregroundStyle(.secondary)
                    eventLog
                }
                .padding(20)
            }
        }
    }

    private var operationInstruction: String {
        switch workflow.progress.first(where: { $0.status == .running })?.id {
        case "authorize": return "请在 macOS 管理员授权弹窗中继续或取消。此时尚未执行启动设置。"
        case "set": return "正在设置下一次启动，请等待工具返回结果。关闭应用不能撤销已提交的选择。"
        case "restart": return "正在请求正常重启，请处理系统的文档保存提示。取消重启不会撤销临时选择。"
        default: return "正在核对目标身份与状态，请等待结果。"
        }
    }

    private func stepIcon(_ status: OperationProgress.Status) -> String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle"
        case .unknown: return "questionmark.circle"
        case .cancelled: return "minus.circle"
        default: return "circle"
        }
    }
    private func stepColor(_ status: OperationProgress.Status) -> Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .unknown: return .orange
        default: return .secondary
        }
    }
    private func stepStatus(_ step: OperationProgress) -> String {
        switch step.status {
        case .waiting: return "待进行"
        case .running: return "已等待 \(max(0, Int(ProcessInfo.processInfo.systemUptime - (step.startedAt ?? ProcessInfo.processInfo.systemUptime)))) 秒"
        case .completed: return "完成 · \(Int(step.elapsed)) 秒"
        case .failed: return "失败"
        case .unknown: return "无法确认"
        case .cancelled: return "已取消"
        }
    }

    private var eventLog: some View {
        DisclosureGroup("查看本次操作记录") {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(workflow.events) { event in
                        HStack(alignment: .top, spacing: 8) {
                            Text(event.date, style: .time).monospacedDigit()
                            Text(event.message)
                            Spacer()
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 120)
        }
        .font(.callout)
    }

    private func operationTargetView(_ target: SystemCandidate) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("目标：\(target.name)").font(.headline)
            Text("\(target.storageDescription) · 标识 \(workflow.targetIdentifier(target))")
                .font(.callout).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var resultStateView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: resultIcon).font(.largeTitle).foregroundStyle(resultColor)
                    .accessibilityHidden(true)
                Text(workflow.resultTitle).font(.title3.weight(.semibold))
                if workflow.resultKind != .scanFailed, let target = workflow.operationTarget {
                    operationTargetView(target)
                }
                Text(workflow.errorMessage ?? workflow.statusMessage ?? "请查看本次操作记录。")
                    .fixedSize(horizontal: false, vertical: true)
                if workflow.resultKind == .restartRequested {
                    Text("请求已提交不代表已经重启或已进入目标系统。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !workflow.events.isEmpty { eventLog }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private var resultIcon: String {
        switch workflow.resultKind {
        case .restartRequested: return "arrow.triangle.2.circlepath"
        case .settingUnknown, .restartUnknown: return "questionmark.circle"
        case .restartFailed: return "exclamationmark.triangle"
        default: return "xmark.circle"
        }
    }
    private var resultColor: Color {
        switch workflow.resultKind {
        case .restartRequested: return .accentColor
        case .settingUnknown, .restartUnknown, .restartFailed: return .orange
        default: return .red
        }
    }

    private var footerBar: some View {
        HStack(spacing: 12) {
            if workflow.phase == .ready || workflow.phase == .confirming {
                Text(workflow.selectedCandidate == nil ? "请先选择目标系统" : "下一步核对目标并进行认证")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("继续…") { workflow.requestConfirmation() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(workflow.phase != .ready || workflow.selectedCandidate?.canSwitch != true)
            } else if workflow.phase == .failed || workflow.phase == .indeterminate || workflow.phase == .restartRequested {
                Text(workflow.bootStateNotice == nil ? "刷新可重新读取系统列表" : "返回列表不撤销临时选择")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("返回系统列表并刷新") { Task { await workflow.scan() } }
            } else {
                Text(workflow.phase == .scanning ? "只读扫描，不改变启动设置" : "请等待当前步骤返回结果")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

private struct ConfirmationView: View {
    @ObservedObject var workflow: SwitchWorkflow
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("确认目标并认证").font(.title3.weight(.semibold))
                    if let target = workflow.selectedCandidate {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("重启到「\(target.name)」？").font(.headline)
                            Text("\(target.version ?? "版本未知") · \(target.storageDescription)")
                            Text("标识：\(workflow.targetIdentifier(target))").monospaced()
                        }
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("设置成功后将请求正常重启。请先保存工作；本次操作不修改默认启动盘。")
                        .font(.callout)
                    Label("取消后续重启不会撤销临时选择；本版本不提供撤销。", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if let notice = workflow.bootStateNotice {
                        Text(notice).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            Text("本机账户")
                            TextField("账户短名称", text: $workflow.ownerUsername)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("本机拥有者账户短名称")
                        }
                        GridRow {
                            Text("登录密码")
                            SecureField("此账户的登录密码", text: $workflow.ownerPassword)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("本机拥有者账户登录密码")
                                .focused($passwordFocused)
                                .onSubmit(submit)
                        }
                    }
                    Text("请确认此账户具有本机拥有者资格。稍后 macOS 会另行请求管理员授权。")
                        .font(.callout).foregroundStyle(.secondary)
                    DisclosureGroup("认证与启动说明") {
                        Text("需使用具有本机拥有者资格的账户短名称及登录密码；管理员授权与拥有者认证分别处理，不能互相替代。密码只用于本次操作，不保存、不进入命令参数或日志。\n本次设置会尝试覆盖其他工具已有的一次性选择，应用不查询或恢复原选择。发现候选系统不保证可启动；外置目标在启动前请保持连接。")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            Divider()
            HStack {
                Button("取消") { workflow.cancelConfirmation() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("认证并重启", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
            .padding(20)
        }
        .frame(width: 480, height: 600)
        .onAppear { passwordFocused = true }
    }

    private var canSubmit: Bool {
        workflow.phase == .confirming
            && !workflow.ownerUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !workflow.ownerPassword.isEmpty
    }
    private func submit() {
        guard canSubmit else { return }
        let username = workflow.ownerUsername
        let password = workflow.ownerPassword
        workflow.ownerPassword = ""
        Task { await workflow.executeSwitch(ownerUsername: username, ownerPassword: password) }
    }
}
