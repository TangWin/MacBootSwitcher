import SwiftUI
import AppKit
import Darwin

@main
enum MacBootSwitcherEntry {
    @MainActor
    static func main() async {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--perform-next-boot" {
            exit(await RestrictedBootRunner.run(socketPath: args[2]))
        }
        guard args.count == 1, geteuid() != 0 else { exit(1) }
        MacBootSwitcherApp.main()
    }
}

struct MacBootSwitcherApp: App {
    @StateObject private var workflow = SwitchWorkflow()
    @NSApplicationDelegateAdaptor(SwitchApplicationDelegate.self) private var delegate
    var body: some Scene {
        Window("MacBootSwitcher", id: "main") {
            ContentView(workflow: workflow)
                .onAppear { delegate.workflow = workflow }
                .background(WindowCloseGuard(workflow: workflow))
        }
        .defaultSize(width: 600, height: 620)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class SwitchApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var workflow: SwitchWorkflow?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard workflow?.blocksNormalClose == true else {
            workflow?.cancelConfirmation()
            return .terminateNow
        }
        showWaitAlert(); return .terminateCancel
    }
}

@MainActor
private func showWaitAlert() {
    let alert = NSAlert()
    alert.messageText = "切换操作仍在执行"
    alert.informativeText = "请等待当前操作返回结果。关闭窗口或退出应用不能撤销已提交的启动选择。"
    alert.addButton(withTitle: "继续等待")
    if let window = NSApp.keyWindow, window.attachedSheet == nil { alert.beginSheetModal(for: window) }
}

@MainActor
private final class GuardedWindowDelegate: NSObject, NSWindowDelegate {
    weak var workflow: SwitchWorkflow?
    weak var original: NSWindowDelegate?
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if workflow?.blocksNormalClose == true { showWaitAlert(); return false }
        let allowed = original?.windowShouldClose?(sender) ?? true
        if allowed { workflow?.cancelConfirmation() }
        return allowed
    }
    override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || original?.responds(to: selector) == true }
    override func forwardingTarget(for selector: Selector!) -> Any? { original }
}

private struct WindowCloseGuard: NSViewRepresentable {
    let workflow: SwitchWorkflow
    func makeCoordinator() -> GuardedWindowDelegate { let delegate = GuardedWindowDelegate(); delegate.workflow = workflow; return delegate }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard let window = nsView.window, window.delegate !== coordinator else { return }
            coordinator.original = window.delegate; window.delegate = coordinator
        }
    }
}
